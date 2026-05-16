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
#include <stdlib.h>
#include <string.h>

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

static size_t header_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  write_ctx *ctx = (write_ctx *)userdata;
  size_t len = size * nmemb;
  return dynbuf_append(&ctx->headers, ptr, len) ? len : 0;
}

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  write_ctx *ctx = (write_ctx *)userdata;
  size_t len = size * nmemb;
  if (!dynbuf_append(&ctx->body, ptr, len)) return 0;
  if (ctx->on_chunk_ref != LUA_NOREF) {
    lua_State *L = ctx->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->on_chunk_ref);
    lua_pushlstring(L, ptr, len);
    /* on_chunk runs deep inside curl_multi_perform's C stack and cannot
     * yield through it; lua_pcall is correct here. */
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
      capture_callback_error(ctx);
      return 0; /* tell curl to abort the transfer */
    }
  }
  return len;
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

static int return_error(lua_State *L, const char *msg) {
  lua_createtable(L, 0, 1);
  lua_pushstring(L, msg);
  lua_setfield(L, -2, "error");
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
    capture_callback_error(&s->ctx);
    s->rc = CURLE_WRITE_ERROR;
    s->done = 1;
    return l_request_finish(L, kctx);
  }

  while (!s->done) {
    if (!coop_pump(s)) break;
    /* yield to the agent loop. lua_callk returns normally if the callback
     * doesn't yield; if the callback calls coroutine.yield, control unwinds
     * out of this C frame and Lua re-enters l_request_step on resume. */
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->yield_ref);
    if (!lua_isfunction(L, -1)) {
      lua_pop(L, 1);
      s->rc = CURLE_FAILED_INIT;
      s->done = 1;
      break;
    }
    lua_callk(L, 0, 0, kctx, l_request_step);
  }

  return l_request_finish(L, kctx);
}

/* Build the response table, free curl/state, and return result count.
 * Called by l_request_step when the loop is done, and by the blocking
 * path in l_request when no yield was supplied. */
static int l_request_finish(lua_State *L, lua_KContext kctx) {
  request_state *s = (request_state *)kctx;

  long http_status = 0;
  curl_easy_getinfo(s->easy, CURLINFO_RESPONSE_CODE, &http_status);

  const char *collected = s->ctx.body.data ? s->ctx.body.data : "";
  size_t collected_len = s->ctx.body.len;
  const char *headers = s->ctx.headers.data ? s->ctx.headers.data : "";
  size_t headers_len = s->ctx.headers.len;

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

  int rv;
  if (s->rc != CURLE_OK) {
    if (s->ctx.callback_error && s->ctx.error_msg_ref != LUA_NOREF) {
      lua_rawgeti(L, LUA_REGISTRYINDEX, s->ctx.error_msg_ref);
      const char *m = lua_tostring(L, -1);
      char buf[512];
      snprintf(buf, sizeof(buf), "callback error: %s", m ? m : "(non-string)");
      lua_pop(L, 1);
      luaL_unref(L, LUA_REGISTRYINDEX, s->ctx.error_msg_ref);
      rv = return_error(L, buf);
    } else {
      const char *msg = curl_easy_strerror(s->rc);
      rv = return_error(L, msg ? msg : "curl error");
    }
  } else {
    rv = return_status(L, http_status, collected, collected_len, headers, headers_len);
  }

  free(s->ctx.body.data);
  free(s->ctx.headers.data);
  free(s);
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
  field_integer(L, 1, "timeout_ms", 600000, &timeout_ms);
  field_integer(L, 1, "connect_timeout_ms", 30000, &connect_timeout_ms);

  int has_yield = has_function_field(L, 1, "yield");
  int on_chunk_ref = ref_function_field(L, 1, "on_chunk");
  int yield_ref = has_yield ? ref_function_field(L, 1, "yield") : LUA_NOREF;
  if (on_chunk_ref == LUA_REFNIL) on_chunk_ref = LUA_NOREF;
  if (yield_ref == LUA_REFNIL) yield_ref = LUA_NOREF;

  CURL *easy = curl_easy_init();
  if (!easy) {
    if (on_chunk_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, on_chunk_ref);
    if (yield_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, yield_ref);
    return return_error(L, "curl_easy_init failed");
  }

  curl_easy_setopt(easy, CURLOPT_URL, url);
  curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
  curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, (long)connect_timeout_ms);

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
    return return_error(L, "out of memory");
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
  s->ctx.body.data = NULL;
  s->ctx.body.len = 0;
  s->ctx.body.cap = 0;
  s->ctx.headers.data = NULL;
  s->ctx.headers.len = 0;
  s->ctx.headers.cap = 0;

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
