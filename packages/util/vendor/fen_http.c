/* Project-owned libcurl binding for fen.util.http.
 *
 * Exposes a single Lua function:
 *
 *   fen_http.request({method, url, headers, body, timeout_ms,
 *                     connect_timeout_ms, on_chunk, yield})
 *     -> {status = N, body = S} | {error = S}
 *
 * Replaces the lua-curl rock dependency. Same contract as the Lua wrapper
 * the providers already use; the swap is invisible to provider code.
 *
 * Cooperative mode (yield given): drive curl_multi by hand so each
 * curl_multi_perform tick is short and the caller's yield runs between
 * ticks. Matches the previous Lua impl's deliberate avoidance of
 * curl_multi_wait, which would block the Lua VM. */

#include <curl/curl.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  lua_State *L;
  luaL_Buffer body;
  int on_chunk_ref;     /* LUA_NOREF when absent */
  int callback_error;   /* set when a Lua callback raised */
  int error_msg_ref;    /* LUA_NOREF until first error; ref to the string */
} write_ctx;

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

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  write_ctx *ctx = (write_ctx *)userdata;
  size_t len = size * nmemb;
  luaL_addlstring(&ctx->body, ptr, len);
  if (ctx->on_chunk_ref != LUA_NOREF) {
    lua_State *L = ctx->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->on_chunk_ref);
    lua_pushlstring(L, ptr, len);
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

static int return_status(lua_State *L, long status, const char *body, size_t body_len) {
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, status);
  lua_setfield(L, -2, "status");
  lua_pushlstring(L, body ? body : "", body_len);
  lua_setfield(L, -2, "body");
  return 1;
}

/* Drive curl_multi cooperatively. Returns CURLcode of the transfer (or
 * CURLE_OK on success). On callback error, sets ctx->callback_error
 * (and captures the Lua error string) and returns CURLE_WRITE_ERROR. */
static CURLcode perform_coop(CURL *easy, int yield_ref, lua_State *L,
                             write_ctx *ctx) {
  CURLM *multi = curl_multi_init();
  if (!multi) return CURLE_OUT_OF_MEMORY;
  CURLMcode mrc = curl_multi_add_handle(multi, easy);
  if (mrc != CURLM_OK) {
    curl_multi_cleanup(multi);
    return CURLE_FAILED_INIT;
  }

  CURLcode result = CURLE_OK;
  int done = 0;
  while (!done) {
    int still_running = 0;
    mrc = curl_multi_perform(multi, &still_running);
    if (mrc != CURLM_OK) {
      result = CURLE_FAILED_INIT;
      break;
    }

    /* drain completion messages for our handle */
    int pending;
    CURLMsg *msg;
    while ((msg = curl_multi_info_read(multi, &pending))) {
      if (msg->msg == CURLMSG_DONE && msg->easy_handle == easy) {
        result = msg->data.result;
        done = 1;
      }
    }

    if (done) break;

    if (ctx->callback_error) {
      result = CURLE_WRITE_ERROR;
      break;
    }

    if (yield_ref != LUA_NOREF) {
      lua_rawgeti(L, LUA_REGISTRYINDEX, yield_ref);
      if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        capture_callback_error(ctx);
        result = CURLE_WRITE_ERROR;
        break;
      }
    }
  }

  curl_multi_remove_handle(multi, easy);
  curl_multi_cleanup(multi);
  return result;
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

  write_ctx ctx;
  ctx.L = L;
  ctx.on_chunk_ref = on_chunk_ref;
  ctx.callback_error = 0;
  ctx.error_msg_ref = LUA_NOREF;
  luaL_buffinit(L, &ctx.body);

  curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(easy, CURLOPT_WRITEDATA, &ctx);

  CURLcode rc;
  if (yield_ref != LUA_NOREF) {
    rc = perform_coop(easy, yield_ref, L, &ctx);
  } else {
    rc = curl_easy_perform(easy);
  }

  long status = 0;
  curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);

  /* finalize body buffer (pushes the assembled string onto the stack) */
  luaL_pushresult(&ctx.body);
  size_t collected_len = 0;
  const char *collected = lua_tolstring(L, -1, &collected_len);

  /* pop body string (we'll repush into result table below) */
  /* keep it on stack until we extract; do that via lua_tolstring then leave
   * on stack as anchor. */

  if (headers) curl_slist_free_all(headers);
  curl_easy_cleanup(easy);

  if (on_chunk_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, on_chunk_ref);
  if (yield_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, yield_ref);

  if (rc != CURLE_OK) {
    if (ctx.callback_error && ctx.error_msg_ref != LUA_NOREF) {
      lua_rawgeti(L, LUA_REGISTRYINDEX, ctx.error_msg_ref);
      const char *m = lua_tostring(L, -1);
      char buf[512];
      snprintf(buf, sizeof(buf), "callback error: %s", m ? m : "(non-string)");
      lua_pop(L, 1);
      luaL_unref(L, LUA_REGISTRYINDEX, ctx.error_msg_ref);
      lua_pop(L, 1); /* body anchor */
      return return_error(L, buf);
    }
    const char *msg = curl_easy_strerror(rc);
    lua_pop(L, 1);
    return return_error(L, msg ? msg : "curl error");
  }

  int rv = return_status(L, status, collected, collected_len);
  /* result table is now on top; remove the body anchor underneath. */
  lua_remove(L, -2);
  return rv;
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
