/* Project-owned libcurl binding for fen.util.http.
 *
 * Exposes a single Lua function:
 *
 *   fen_http.request({method, url, headers, body, timeout_ms,
 *                     connect_timeout_ms, on_chunk, yield})
 *     -> {status = N, body = S, headers = {}} | {error = S}
 *
 * Replaces the lua-curl rock dependency. Same contract as the Lua wrapper
 * the providers already use; the swap is invisible to provider code.
 *
 * Cooperative mode (yield given): drive curl_multi by hand so each
 * curl_multi_perform tick is short and the caller's yield runs between
 * ticks. The yield callback is invoked via lua_callk with a continuation
 * so coroutine.yield() works through the C boundary — required by the
 * agent loop's cancel/yield model. State lives on the heap (request_state)
 * so it survives the C-stack unwind that happens on every yield. */

#include <curl/curl.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* When body accumulation is disabled (streaming success paths build their
 * result from the parsed stream, never resp.body), we still keep a small head
 * so the non-2xx error/diagnostic paths — which read resp.body — have a useful
 * (small) error payload. HTTP error bodies are short JSON; the status isn't
 * known until completion, so we can't decide per-response whether to keep it. */
#define FEN_ERROR_BODY_CAP 65536

/* Max queued bytes fed to on_chunk per cooperative drain slice. Bounds the Lua
 * work (SSE parse → JSON decode → reducer → TUI emit) done between two yields,
 * so a large burst is spread across repaints instead of one un-yielded stall. */
#define FEN_CHUNK_DRAIN_BUDGET 65536

/* Portable millisecond sleep (copy of fen_process.c's sleep_ms_int): retries
 * across EINTR. Only used by the FEN_DEBUG_CHUNK_DELAY_MS debug knob. */
static void fen_http_sleep_ms(long ms) {
  if (ms <= 0) return;
  struct timespec req;
  req.tv_sec = ms / 1000;
  req.tv_nsec = (ms % 1000) * 1000000L;
  while (nanosleep(&req, &req) < 0 && errno == EINTR) {}
}

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} dynbuf;

typedef struct {
  lua_State *L;
  dynbuf body;
  dynbuf headers;
  int on_chunk_ref;     /* LUA_NOREF when absent */
  int callback_error;   /* set when a Lua callback raised */
  int error_msg_ref;    /* LUA_NOREF until first error; ref to the string */
  int accumulate_body;  /* 1 = grow body unbounded; 0 = cap at FEN_ERROR_BODY_CAP */
  /* Cooperative chunk draining. When defer_chunks is set (coop mode with an
   * on_chunk), write_cb only queues raw bytes here; drain_pending feeds them to
   * on_chunk from the yieldable step loop, advancing drain_pos as a cursor. */
  dynbuf pending;
  size_t drain_pos;
  int defer_chunks;
  long chunk_delay_ms;  /* FEN_DEBUG_CHUNK_DELAY_MS; <= 0 disables */
} write_ctx;

/* Heap-allocated coop state. Survives every yield/resume cycle by living
 * outside the C call stack. Freed in l_request_finish. */
typedef struct {
  CURL *easy;
  CURLM *multi;                /* NULL on the blocking path */
  struct curl_slist *headers;  /* NULL when no headers supplied */
  write_ctx ctx;
  int on_chunk_ref;
  int yield_ref;
  CURLcode rc;
  int done;
} request_state;

static int dynbuf_append(dynbuf *b, const char *ptr, size_t len) {
  if (len == 0) return 1;
  if (b->len + len + 1 > b->cap) {
    size_t next = b->cap ? b->cap * 2 : 4096;
    while (next < b->len + len + 1) next *= 2;
    char *p = (char *)realloc(b->data, next);
    if (!p) return 0;
    b->data = p;
    b->cap = next;
  }
  memcpy(b->data + b->len, ptr, len);
  b->len += len;
  b->data[b->len] = '\0';
  return 1;
}

static void capture_callback_error(write_ctx *ctx) {
  /* Lua error message is on top of the stack. Hold the first one in the
   * registry so the abort path can surface it; drop subsequent errors. */
  if (ctx->error_msg_ref == LUA_NOREF) {
    ctx->error_msg_ref = luaL_ref(ctx->L, LUA_REGISTRYINDEX);
  } else {
    lua_pop(ctx->L, 1);
  }
  ctx->callback_error = 1;
}

static int field_string(lua_State *L, int idx, const char *key, const char **out,
                        size_t *out_len) {
  lua_getfield(L, idx, key);
  int t = lua_type(L, -1);
  if (t == LUA_TNIL) {
    *out = NULL;
    if (out_len) *out_len = 0;
    lua_pop(L, 1);
    return 0;
  }
  if (t != LUA_TSTRING) {
    lua_pop(L, 1);
    return luaL_error(L, "fen_http.request: '%s' must be a string", key);
  }
  size_t len = 0;
  const char *s = lua_tolstring(L, -1, &len);
  /* keep on stack so the C string stays alive for the duration of the call.
   * caller is responsible for not popping until done with the pointer. */
  if (out_len) *out_len = len;
  *out = s;
  return 1;
}

static int field_integer(lua_State *L, int idx, const char *key, lua_Integer dflt,
                         lua_Integer *out) {
  lua_getfield(L, idx, key);
  int t = lua_type(L, -1);
  if (t == LUA_TNIL) {
    *out = dflt;
    lua_pop(L, 1);
    return 0;
  }
  if (t != LUA_TNUMBER) {
    lua_pop(L, 1);
    return luaL_error(L, "fen_http.request: '%s' must be a number", key);
  }
  *out = lua_tointeger(L, -1);
  lua_pop(L, 1);
  return 1;
}

static int field_boolean(lua_State *L, int idx, const char *key, int dflt,
                         int *out) {
  lua_getfield(L, idx, key);
  int t = lua_type(L, -1);
  if (t == LUA_TNIL) {
    *out = dflt;
    lua_pop(L, 1);
    return 0;
  }
  if (t != LUA_TBOOLEAN) {
    lua_pop(L, 1);
    return luaL_error(L, "fen_http.request: '%s' must be a boolean", key);
  }
  *out = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return 1;
}

static size_t header_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  write_ctx *ctx = (write_ctx *)userdata;
  size_t len = size * nmemb;
  return dynbuf_append(&ctx->headers, ptr, len) ? len : 0;
}

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  write_ctx *ctx = (write_ctx *)userdata;
  size_t len = size * nmemb;
  if (ctx->accumulate_body) {
    if (!dynbuf_append(&ctx->body, ptr, len)) return 0;
  } else if (ctx->body.len < FEN_ERROR_BODY_CAP) {
    /* Keep only a bounded head for error diagnostics; capping is not an error,
     * so a full cap never aborts the transfer. */
    size_t room = FEN_ERROR_BODY_CAP - ctx->body.len;
    size_t take = len < room ? len : room;
    if (!dynbuf_append(&ctx->body, ptr, take)) return 0;
  }
  if (ctx->on_chunk_ref != LUA_NOREF) {
    if (ctx->defer_chunks) {
      /* Cooperative path: only queue raw bytes here. Calling on_chunk would
       * run deep inside curl_multi_perform's non-yieldable C stack; instead
       * drain_pending feeds these bytes from the yieldable step loop, bounded
       * per slice, with a yield between slices. Pure C, no lua_* call. */
      if (!dynbuf_append(&ctx->pending, ptr, len)) return 0;
    } else {
      /* Blocking path: no step loop to drain into, so call on_chunk inline.
       * lua_pcall (not pcallk) is correct — we cannot yield through libcurl. */
      lua_State *L = ctx->L;
      lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->on_chunk_ref);
      lua_pushlstring(L, ptr, len);
      if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        capture_callback_error(ctx);
        return 0; /* tell curl to abort the transfer */
      }
    }
  }
  return len;
}

/* Feed up to FEN_CHUNK_DRAIN_BUDGET queued bytes through on_chunk, advancing a
 * cursor (no per-slice memmove). Runs only in the yieldable step frame, never
 * inside curl_multi_perform. Returns 1 if work remains, 0 if the queue is now
 * empty, -1 if on_chunk raised (callback_error captured; caller must abort). */
static int drain_pending(write_ctx *ctx) {
  if (ctx->on_chunk_ref == LUA_NOREF || ctx->drain_pos >= ctx->pending.len) {
    /* Fully drained (or nothing to drain): reset for reuse, keep the alloc. */
    ctx->pending.len = 0;
    ctx->drain_pos = 0;
    return 0;
  }
  size_t avail = ctx->pending.len - ctx->drain_pos;
  size_t take = avail < FEN_CHUNK_DRAIN_BUDGET ? avail : FEN_CHUNK_DRAIN_BUDGET;
  fen_http_sleep_ms(ctx->chunk_delay_ms); /* debug: simulate slow per-chunk cost */
  lua_State *L = ctx->L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->on_chunk_ref);
  lua_pushlstring(L, ctx->pending.data + ctx->drain_pos, take);
  if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
    capture_callback_error(ctx);
    return -1;
  }
  ctx->drain_pos += take;
  if (ctx->drain_pos >= ctx->pending.len) {
    ctx->pending.len = 0;
    ctx->drain_pos = 0;
    return 0;
  }
  return 1;
}

static struct curl_slist *build_header_list(lua_State *L, int idx) {
  lua_getfield(L, idx, "headers");
  int t = lua_type(L, -1);
  if (t == LUA_TNIL) {
    lua_pop(L, 1);
    return NULL;
  }
  if (t != LUA_TTABLE) {
    lua_pop(L, 1);
    luaL_error(L, "fen_http.request: 'headers' must be a table");
    return NULL;
  }
  struct curl_slist *list = NULL;
  lua_pushnil(L);
  while (lua_next(L, -2) != 0) {
    /* key at -2, value at -1 */
    const char *k = lua_tostring(L, -2);
    const char *v = lua_tostring(L, -1);
    if (k && v) {
      size_t klen = strlen(k);
      size_t vlen = strlen(v);
      char *buf = (char *)malloc(klen + vlen + 3);
      if (!buf) {
        curl_slist_free_all(list);
        lua_pop(L, 3);
        luaL_error(L, "fen_http.request: out of memory");
        return NULL;
      }
      memcpy(buf, k, klen);
      buf[klen] = ':';
      buf[klen + 1] = ' ';
      memcpy(buf + klen + 2, v, vlen);
      buf[klen + 2 + vlen] = '\0';
      struct curl_slist *next = curl_slist_append(list, buf);
      free(buf);
      if (!next) {
        curl_slist_free_all(list);
        lua_pop(L, 3);
        luaL_error(L, "fen_http.request: curl_slist_append failed");
        return NULL;
      }
      list = next;
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1); /* headers table */
  return list;
}

static int has_function_field(lua_State *L, int idx, const char *key) {
  lua_getfield(L, idx, key);
  int is_fn = lua_isfunction(L, -1);
  lua_pop(L, 1);
  return is_fn;
}

static int ref_function_field(lua_State *L, int idx, const char *key) {
  lua_getfield(L, idx, key);
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 1);
    return LUA_NOREF;
  }
  return luaL_ref(L, LUA_REGISTRYINDEX);
}

static int return_error(lua_State *L, const char *msg, int curl_code) {
  lua_createtable(L, 0, curl_code ? 2 : 1);
  lua_pushstring(L, msg);
  lua_setfield(L, -2, "error");
  if (curl_code) {
    lua_pushinteger(L, curl_code);
    lua_setfield(L, -2, "curl_code");
  }
  return 1;
}

static void trim_span(const char **start, const char **end) {
  while (*start < *end && (**start == ' ' || **start == '\t')) (*start)++;
  while (*end > *start && ((*(*end - 1) == ' ') || (*(*end - 1) == '\t') ||
                           (*(*end - 1) == '\r') || (*(*end - 1) == '\n'))) (*end)--;
}

static void push_headers_table(lua_State *L, const char *raw, size_t raw_len) {
  lua_createtable(L, 0, 8);
  const char *p = raw;
  const char *limit = raw + raw_len;
  while (p < limit) {
    const char *line_end = memchr(p, '\n', (size_t)(limit - p));
    if (!line_end) line_end = limit;
    const char *colon = memchr(p, ':', (size_t)(line_end - p));
    if (colon) {
      const char *k0 = p;
      const char *k1 = colon;
      const char *v0 = colon + 1;
      const char *v1 = line_end;
      trim_span(&k0, &k1);
      trim_span(&v0, &v1);
      if (k1 > k0) {
        lua_pushlstring(L, k0, (size_t)(k1 - k0));
        lua_pushlstring(L, v0, (size_t)(v1 - v0));
        lua_settable(L, -3);
      }
    }
    p = (line_end < limit) ? line_end + 1 : limit;
  }
}

static int return_status(lua_State *L, long status, const char *body, size_t body_len,
                         const char *headers, size_t headers_len) {
  lua_createtable(L, 0, 3);
  lua_pushinteger(L, status);
  lua_setfield(L, -2, "status");
  lua_pushlstring(L, body ? body : "", body_len);
  lua_setfield(L, -2, "body");
  push_headers_table(L, headers ? headers : "", headers_len);
  lua_setfield(L, -2, "headers");
  return 1;
}

static int l_request_finish(lua_State *L, lua_KContext kctx);
static int l_request_step(lua_State *L, int status, lua_KContext kctx);
static void free_request_state(lua_State *L, request_state *s);

/* One iteration of curl_multi_perform + completion drain. Returns 1 if
 * the loop should yield to the caller and resume; 0 if the request is
 * done (or has errored) and the caller should call l_request_finish. */
static int coop_pump(request_state *s) {
  int still_running = 0;
  CURLMcode mrc = curl_multi_perform(s->multi, &still_running);
  if (mrc != CURLM_OK) {
    s->rc = CURLE_FAILED_INIT;
    s->done = 1;
    return 0;
  }
  int pending;
  CURLMsg *msg;
  while ((msg = curl_multi_info_read(s->multi, &pending))) {
    if (msg->msg == CURLMSG_DONE && msg->easy_handle == s->easy) {
      s->rc = msg->data.result;
      s->done = 1;
    }
  }
  if (s->done) return 0;
  if (s->ctx.callback_error) {
    s->rc = CURLE_WRITE_ERROR;
    s->done = 1;
    return 0;
  }
  return 1;
}

/* Continuation-aware step. Called once directly from l_request to start the
 * coop loop; thereafter called by Lua as the lua_callk continuation when
 * the user's yield callback resumes (status == LUA_YIELD). On resume after
 * a callback that errored, status reports the pcall failure and we route
 * to l_request_finish through the callback_error path. */
static int l_request_step(lua_State *L, int status, lua_KContext kctx) {
  request_state *s = (request_state *)kctx;

  if (status != LUA_OK && status != LUA_YIELD) {
    /* The yield callback raised after resuming (e.g. the agent loop's cancel
     * marker). lua_pcallk leaves the error object on the stack top and does
     * not unwind it. Free every owned resource, then re-raise the original
     * error so its value — and table identity, which the agent compares the
     * cancel marker by — propagates to the caller's pcall. We must NOT turn
     * it into a returned {error=...} table: that would mask a clean cancel as
     * a transport failure. */
    free_request_state(L, s);
    return lua_error(L);
  }

  /* Loop until curl is done AND every queued byte has been drained. Each
   * iteration performs at most one curl tick and drains at most one bounded
   * slice, then yields — so a large burst is spread across repaints (one slice
   * per yield) instead of running as a single un-yielded stall. Critically the
   * remainder left after curl completes is flushed the SAME way: still one
   * slice per yield, so a late bulk burst can't stall the final resume. */
  while (1) {
    /* Backpressure: pump curl only when the queue is fully drained, so a
     * producer faster than the bounded drain can't grow `pending` to the whole
     * stream size — which would defeat accumulate_body=false (issue #167 M2) by
     * just moving the multi-MB buffer from `body` into `pending`. Unread bytes
     * stay in the OS socket buffer and TCP flow control throttles the sender
     * until we catch up. A pump adds at most one socket buffer's worth, drained
     * over a handful of bounded slices before the next pump. */
    int pending_remains = (s->ctx.drain_pos < s->ctx.pending.len);
    if (!s->done && !pending_remains) coop_pump(s); /* may set s->done */
    /* Drain one bounded slice. A drain failure (on_chunk raised) aborts the
     * transfer the same way a write error would. */
    int d = drain_pending(&s->ctx);
    if (d < 0) {
      s->rc = CURLE_WRITE_ERROR;
      s->done = 1;
      break;
    }
    pending_remains = (s->ctx.drain_pos < s->ctx.pending.len);
    /* Done with the transfer and nothing left to deliver: finish. */
    if (s->done && !pending_remains) break;
    /* Poll for socket readiness only while the transfer is live; once curl is
     * done we are just draining the queue and there is nothing to wait on.
     * While queued bytes remain, poll with a 0 timeout so draining keeps pace
     * with arrival instead of waiting out the cap. */
    if (!s->done) {
      int numfds = 0;
      int poll_ms = pending_remains ? 0 : 50;
#if LIBCURL_VERSION_NUM >= 0x074200 /* 7.66.0 */
      curl_multi_poll(s->multi, NULL, 0, poll_ms, &numfds);
#else
      curl_multi_wait(s->multi, NULL, 0, poll_ms, &numfds);
#endif
      (void)numfds;
    }
    /* yield to the agent loop. lua_pcallk returns normally if the callback
     * doesn't yield; if the callback calls coroutine.yield, control unwinds
     * out of this C frame and Lua re-enters l_request_step on resume. Using
     * the protected form means a raise on resume lands in the branch above
     * (with cleanup) rather than longjmp-ing past l_request_finish. */
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->yield_ref);
    if (!lua_isfunction(L, -1)) {
      lua_pop(L, 1);
      s->rc = CURLE_FAILED_INIT;
      s->done = 1;
      break;
    }
    {
      int st = lua_pcallk(L, 0, 0, 0, kctx, l_request_step);
      if (st != LUA_OK) {
        /* Synchronous error: the callback raised without yielding first.
         * Same handling as the resume-error branch above. */
        free_request_state(L, s);
        return lua_error(L);
      }
    }
  }

  return l_request_finish(L, kctx);
}

/* Free every curl/registry/heap resource owned by `s`, then free `s` itself.
 * Only touches the Lua registry (via luaL_unref), never the data stack, so a
 * value already on the stack top (e.g. an error object being re-raised, or a
 * just-built response table) survives the call. Safe to call exactly once;
 * `s` is invalid afterwards. */
static void free_request_state(lua_State *L, request_state *s) {
  if (s->multi) {
    curl_multi_remove_handle(s->multi, s->easy);
    curl_multi_cleanup(s->multi);
  }
  if (s->headers) curl_slist_free_all(s->headers);
  curl_easy_cleanup(s->easy);
  if (s->on_chunk_ref != LUA_NOREF)
    luaL_unref(L, LUA_REGISTRYINDEX, s->on_chunk_ref);
  if (s->yield_ref != LUA_NOREF)
    luaL_unref(L, LUA_REGISTRYINDEX, s->yield_ref);
  if (s->ctx.error_msg_ref != LUA_NOREF)
    luaL_unref(L, LUA_REGISTRYINDEX, s->ctx.error_msg_ref);
  free(s->ctx.body.data);
  free(s->ctx.headers.data);
  free(s->ctx.pending.data);
  free(s);
}

/* Build the response table, free curl/state, and return result count.
 * Called by l_request_step when the loop is done, and by the blocking
 * path in l_request when no yield was supplied. */
static int l_request_finish(lua_State *L, lua_KContext kctx) {
  request_state *s = (request_state *)kctx;

  long http_status = 0;
  curl_easy_getinfo(s->easy, CURLINFO_RESPONSE_CODE, &http_status);

  /* Build the result onto the stack while the buffers and error_msg_ref are
   * still alive; free_request_state below only does registry unrefs and heap
   * frees, so the freshly pushed table on the stack top is unaffected. */
  int rv;
  if (s->rc != CURLE_OK) {
    if (s->ctx.callback_error && s->ctx.error_msg_ref != LUA_NOREF) {
      lua_rawgeti(L, LUA_REGISTRYINDEX, s->ctx.error_msg_ref);
      const char *m = lua_tostring(L, -1);
      char buf[512];
      snprintf(buf, sizeof(buf), "callback error: %s", m ? m : "(non-string)");
      lua_pop(L, 1);
      rv = return_error(L, buf, 0);
    } else {
      const char *msg = curl_easy_strerror(s->rc);
      rv = return_error(L, msg ? msg : "curl error", (int)s->rc);
    }
  } else {
    const char *collected = s->ctx.body.data ? s->ctx.body.data : "";
    size_t collected_len = s->ctx.body.len;
    const char *headers = s->ctx.headers.data ? s->ctx.headers.data : "";
    size_t headers_len = s->ctx.headers.len;
    rv = return_status(L, http_status, collected, collected_len, headers, headers_len);
  }

  free_request_state(L, s);
  return rv;
}

static int l_request(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);

  const char *method = NULL;
  const char *url = NULL;
  const char *body = NULL;
  size_t body_len = 0;
  size_t method_len = 0;
  field_string(L, 1, "method", &method, &method_len);
  /* leaves method on stack */
  field_string(L, 1, "url", &url, NULL);
  /* leaves url on stack */
  if (!url) {
    return luaL_error(L, "fen_http.request: 'url' is required");
  }
  field_string(L, 1, "body", &body, &body_len);
  /* leaves body on stack */

  lua_Integer timeout_ms = 0;
  lua_Integer connect_timeout_ms = 0;
  lua_Integer idle_timeout_ms = 0;
  field_integer(L, 1, "timeout_ms", 600000, &timeout_ms);
  field_integer(L, 1, "connect_timeout_ms", 30000, &connect_timeout_ms);
  /* Idle/stall watchdog: abort if throughput stays below 1 byte/s for this
   * many ms (default supplied by the Lua backend). Without it a stream that
   * connects then goes silent hangs until the whole-request timeout_ms. */
  field_integer(L, 1, "idle_timeout_ms", 60000, &idle_timeout_ms);

  /* Default true: callers that don't opt out keep the documented contract that
   * resp.body holds the full response. Streaming callers pass false to skip
   * accumulating a multi-MB body they build from the parsed stream instead. */
  int accumulate_body = 1;
  field_boolean(L, 1, "accumulate_body", 1, &accumulate_body);

  /* FEN_DEBUG_CHUNK_DELAY_MS: simulate slow per-chunk processing on fast
   * hardware (sleep this many ms per drain slice). No-op when unset or <= 0.
   * Read once, like FEN_HTTP_IDLE_TIMEOUT_MS below. */
  long chunk_delay_ms = 0;
  {
    const char *d = getenv("FEN_DEBUG_CHUNK_DELAY_MS");
    if (d && d[0] != '\0') {
      long v = strtol(d, NULL, 10);
      if (v > 0) chunk_delay_ms = v;
    }
  }

  int has_yield = has_function_field(L, 1, "yield");
  int on_chunk_ref = ref_function_field(L, 1, "on_chunk");
  int yield_ref = has_yield ? ref_function_field(L, 1, "yield") : LUA_NOREF;
  if (on_chunk_ref == LUA_REFNIL) on_chunk_ref = LUA_NOREF;
  if (yield_ref == LUA_REFNIL) yield_ref = LUA_NOREF;
  /* Defer chunk delivery only when we have both a yield (a step loop to drain
   * from) and an on_chunk (something to deliver). Otherwise write_cb keeps the
   * inline/blocking behavior. */
  int defer_chunks = (yield_ref != LUA_NOREF) && (on_chunk_ref != LUA_NOREF);

  CURL *easy = curl_easy_init();
  if (!easy) {
    if (on_chunk_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, on_chunk_ref);
    if (yield_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, yield_ref);
    return return_error(L, "curl_easy_init failed", CURLE_FAILED_INIT);
  }

  curl_easy_setopt(easy, CURLOPT_URL, url);
  curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
  curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, (long)connect_timeout_ms);

  /* FEN_HTTP_IDLE_TIMEOUT_MS overrides the per-call idle window (operator
   * escape hatch, like CURL_CA_BUNDLE below). <= 0 disables the watchdog.
   * CURLOPT_LOW_SPEED_TIME is in seconds; we expose ms for API symmetry and
   * round up to at least 1s. A low-speed abort surfaces as
   * CURLE_OPERATION_TIMEDOUT (28), which the retry layer treats as transient. */
  {
    const char *idle_env = getenv("FEN_HTTP_IDLE_TIMEOUT_MS");
    if (idle_env && idle_env[0] != '\0') {
      idle_timeout_ms = (lua_Integer)strtol(idle_env, NULL, 10);
    }
    if (idle_timeout_ms > 0) {
      /* Ceiling division: any positive idle_timeout_ms yields at least 1s. */
      long idle_secs = (long)((idle_timeout_ms + 999) / 1000);
      curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, 1L);
      curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, idle_secs);
    }
  }

  /* Let operators override libcurl's compiled-in CA bundle on minimal or
   * older devices. Prefer curl's conventional variable, then OpenSSL's.
   * Empty variables are ignored so libcurl keeps its default CA lookup. */
  const char *ca_path = getenv("CURL_CA_BUNDLE");
  if (!ca_path || ca_path[0] == '\0') ca_path = getenv("SSL_CERT_FILE");
  if (ca_path && ca_path[0] != '\0') {
    curl_easy_setopt(easy, CURLOPT_CAINFO, ca_path);
  }

  int is_post = (method && (strcmp(method, "POST") == 0 || strcmp(method, "post") == 0));
  if (is_post) {
    curl_easy_setopt(easy, CURLOPT_POST, 1L);
    if (body) {
      curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE, (long)body_len);
      curl_easy_setopt(easy, CURLOPT_POSTFIELDS, body);
    } else {
      curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE, 0L);
      curl_easy_setopt(easy, CURLOPT_POSTFIELDS, "");
    }
  } else {
    curl_easy_setopt(easy, CURLOPT_HTTPGET, 1L);
  }

  struct curl_slist *headers = build_header_list(L, 1);
  if (headers) curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headers);

  request_state *s = (request_state *)malloc(sizeof(request_state));
  if (!s) {
    if (headers) curl_slist_free_all(headers);
    curl_easy_cleanup(easy);
    if (on_chunk_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, on_chunk_ref);
    if (yield_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, yield_ref);
    return return_error(L, "out of memory", CURLE_OUT_OF_MEMORY);
  }
  s->easy = easy;
  s->multi = NULL;
  s->headers = headers;
  s->on_chunk_ref = on_chunk_ref;
  s->yield_ref = yield_ref;
  s->rc = CURLE_OK;
  s->done = 0;
  s->ctx.L = L;
  s->ctx.on_chunk_ref = on_chunk_ref;
  s->ctx.callback_error = 0;
  s->ctx.error_msg_ref = LUA_NOREF;
  s->ctx.accumulate_body = accumulate_body;
  s->ctx.defer_chunks = defer_chunks;
  s->ctx.chunk_delay_ms = chunk_delay_ms;
  s->ctx.drain_pos = 0;
  s->ctx.body.data = NULL;
  s->ctx.body.len = 0;
  s->ctx.body.cap = 0;
  s->ctx.headers.data = NULL;
  s->ctx.headers.len = 0;
  s->ctx.headers.cap = 0;
  s->ctx.pending.data = NULL;
  s->ctx.pending.len = 0;
  s->ctx.pending.cap = 0;

  curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(easy, CURLOPT_WRITEDATA, &s->ctx);
  curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, header_cb);
  curl_easy_setopt(easy, CURLOPT_HEADERDATA, &s->ctx);

  if (yield_ref == LUA_NOREF) {
    /* Blocking path: drive curl_easy_perform synchronously. */
    s->rc = curl_easy_perform(easy);
    s->done = 1;
    return l_request_finish(L, (lua_KContext)s);
  }

  /* Cooperative path: drive curl_multi by hand so the yield callback
   * runs between perform ticks, and use lua_callk so coroutine.yield()
   * can suspend through this C frame. */
  s->multi = curl_multi_init();
  if (!s->multi) {
    s->rc = CURLE_OUT_OF_MEMORY;
    s->done = 1;
    return l_request_finish(L, (lua_KContext)s);
  }
  if (curl_multi_add_handle(s->multi, easy) != CURLM_OK) {
    s->rc = CURLE_FAILED_INIT;
    s->done = 1;
    return l_request_finish(L, (lua_KContext)s);
  }
  return l_request_step(L, LUA_OK, (lua_KContext)s);
}

static const luaL_Reg lib[] = {
    {"request", l_request},
    {NULL, NULL},
};

int luaopen_fen_http(lua_State *L) {
  /* curl_global_init is documented as not thread-safe; call it lazily here.
   * Double-init is a no-op refcount in libcurl. */
  curl_global_init(CURL_GLOBAL_DEFAULT);
  luaL_newlib(L, lib);
  return 1;
}
