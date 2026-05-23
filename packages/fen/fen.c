#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <zip/zip.h>

extern int luaopen_cjson(lua_State *L);
extern int luaopen_termbox2(lua_State *L);
extern int luaopen_fen_http(lua_State *L);
extern int luaopen_fen_process(lua_State *L);
extern int luaopen_fen_random(lua_State *L);
extern int luaopen_lfs(lua_State *L);

static struct zip_t *embedded_zip = NULL;
/* Address used as a stable LUA_REGISTRYINDEX key for the cached fennel module
 * table. Avoids re-requiring fennel on every .fnl load. */
static char fennel_registry_key = 0;

static char *module_to_path(lua_State *L, const char *modname, const char *suffix) {
  size_t mod_len = strlen(modname);
  size_t suffix_len = strlen(suffix);
  char *path = (char *)lua_newuserdatauv(L, mod_len + suffix_len + 1, 0);
  for (size_t i = 0; i < mod_len; i++) {
    path[i] = (modname[i] == '.') ? '/' : modname[i];
  }
  memcpy(path + mod_len, suffix, suffix_len + 1);
  return path;
}

static int try_load_zip_entry(lua_State *L, const char *zip_path) {
  int open_rc = zip_entry_opencasesensitive(embedded_zip, zip_path);
  if (open_rc != 0) {
    return 0;
  }

  void *buf = NULL;
  size_t size = 0;
  ssize_t read_rc = zip_entry_read(embedded_zip, &buf, &size);
  zip_entry_close(embedded_zip);

  if (read_rc < 0 || buf == NULL) {
    lua_pushfstring(L, "error reading embedded module '%s': %s", zip_path,
                    zip_strerror((int)read_rc));
    return -1;
  }

  char chunkname[PATH_MAX + 16];
  snprintf(chunkname, sizeof(chunkname), "@embedded:%s", zip_path);
  int load_rc = luaL_loadbufferx(L, (const char *)buf, size, chunkname, "t");
  free(buf);

  if (load_rc != LUA_OK) {
    return -1;
  }
  return 1;
}

/* Push fennel.compileString onto the stack. Returns 1 on success (one value
 * pushed), -1 on failure (error string pushed). The fennel module is cached
 * in the registry so subsequent calls pay no require overhead. */
static int push_fennel_compile_string(lua_State *L) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &fennel_registry_key);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1); /* nil */
    lua_getglobal(L, "require");
    lua_pushstring(L, "fennel");
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
      return -1;
    }
    lua_pushvalue(L, -1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &fennel_registry_key);
  }
  lua_getfield(L, -1, "compileString");
  lua_remove(L, -2); /* fennel module */
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 1);
    lua_pushliteral(L, "fennel.compileString is not a function");
    return -1;
  }
  return 1;
}

static int try_compile_zip_entry(lua_State *L, const char *zip_path) {
  int open_rc = zip_entry_opencasesensitive(embedded_zip, zip_path);
  if (open_rc != 0) {
    return 0;
  }

  void *buf = NULL;
  size_t size = 0;
  ssize_t read_rc = zip_entry_read(embedded_zip, &buf, &size);
  zip_entry_close(embedded_zip);

  if (read_rc < 0 || buf == NULL) {
    lua_pushfstring(L, "error reading embedded fnl module '%s': %s", zip_path,
                    zip_strerror((int)read_rc));
    return -1;
  }

  if (push_fennel_compile_string(L) < 0) {
    free(buf);
    return -1;
  }

  char chunkname[PATH_MAX + 16];
  snprintf(chunkname, sizeof(chunkname), "@embedded:%s", zip_path);

  lua_pushlstring(L, (const char *)buf, size);
  free(buf);
  lua_createtable(L, 0, 1);
  lua_pushstring(L, chunkname);
  lua_setfield(L, -2, "filename");

  if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
    return -1;
  }

  size_t compiled_len = 0;
  const char *compiled = lua_tolstring(L, -1, &compiled_len);
  if (!compiled) {
    lua_pop(L, 1);
    lua_pushfstring(L, "fennel.compileString returned non-string for '%s'",
                    zip_path);
    return -1;
  }
  int load_rc = luaL_loadbufferx(L, compiled, compiled_len, chunkname, "t");
  lua_remove(L, -2); /* compiled source string */
  if (load_rc != LUA_OK) {
    return -1;
  }
  return 1;
}

static int embedded_zip_searcher(lua_State *L) {
  const char *modname = luaL_checkstring(L, 1);

  char *lua_path = module_to_path(L, modname, ".lua");
  int rc = try_load_zip_entry(L, lua_path);
  if (rc == 1) {
    return 1;
  }
  if (rc < 0) {
    return lua_error(L);
  }
  lua_pop(L, 1); /* userdata path */

  char *init_path = module_to_path(L, modname, "/init.lua");
  rc = try_load_zip_entry(L, init_path);
  if (rc == 1) {
    return 1;
  }
  if (rc < 0) {
    return lua_error(L);
  }
  lua_pop(L, 1); /* userdata path */

  lua_pushfstring(L, "\n\tno embedded module '%s'", modname);
  return 1;
}

static int embedded_fennel_searcher(lua_State *L) {
  const char *modname = luaL_checkstring(L, 1);

  char *fnl_path = module_to_path(L, modname, ".fnl");
  int rc = try_compile_zip_entry(L, fnl_path);
  if (rc == 1) {
    return 1;
  }
  if (rc < 0) {
    return lua_error(L);
  }
  lua_pop(L, 1); /* userdata path */

  char *init_path = module_to_path(L, modname, "/init.fnl");
  rc = try_compile_zip_entry(L, init_path);
  if (rc == 1) {
    return 1;
  }
  if (rc < 0) {
    return lua_error(L);
  }
  lua_pop(L, 1); /* userdata path */

  lua_pushfstring(L, "\n\tno embedded fnl module '%s'", modname);
  return 1;
}

/* --- Dev-path overlay helpers -------------------------------------------- */

typedef struct {
  char **items;
  size_t count;
  size_t cap;
} str_list;

static void str_list_init(str_list *l) {
  l->items = NULL;
  l->count = 0;
  l->cap = 0;
}

static void str_list_push_owned(str_list *l, char *s) {
  if (l->count == l->cap) {
    l->cap = l->cap ? l->cap * 2 : 4;
    l->items = (char **)realloc(l->items, l->cap * sizeof(char *));
  }
  l->items[l->count++] = s;
}

static void str_list_push(str_list *l, const char *s) {
  size_t n = strlen(s);
  char *copy = (char *)malloc(n + 1);
  memcpy(copy, s, n + 1);
  str_list_push_owned(l, copy);
}

static void str_list_push_colon_split(str_list *l, const char *colon_list) {
  if (!colon_list || !*colon_list) return;
  const char *p = colon_list;
  while (*p) {
    const char *seg = p;
    while (*p && *p != ':') p++;
    if (p > seg) {
      size_t n = (size_t)(p - seg);
      char *copy = (char *)malloc(n + 1);
      memcpy(copy, seg, n);
      copy[n] = '\0';
      str_list_push_owned(l, copy);
    }
    if (*p == ':') p++;
  }
}

static void str_list_free(str_list *l) {
  for (size_t i = 0; i < l->count; i++) free(l->items[i]);
  free(l->items);
}

/* Build a fennel-flavoured analog of a Lua package.path: each ;-separated
 * template ending in ".lua" is rewritten to end in ".fnl"; templates that
 * don't end in ".lua" are dropped. Pushes the result on the Lua stack. */
static void push_fnl_path(lua_State *L, const char *lua_path) {
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  int first = 1;
  const char *p = lua_path;
  while (*p) {
    const char *seg = p;
    while (*p && *p != ';') p++;
    size_t seg_len = (size_t)(p - seg);
    if (seg_len >= 4 && memcmp(seg + seg_len - 4, ".lua", 4) == 0) {
      if (!first) luaL_addchar(&b, ';');
      luaL_addlstring(&b, seg, seg_len - 4);
      luaL_addlstring(&b, ".fnl", 4);
      first = 0;
    }
    if (*p == ';') p++;
  }
  luaL_pushresult(&b);
}

static long slurp_file(const char *path, char **out) {
  FILE *f = fopen(path, "rb");
  if (!f) return -1;
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
  long size = ftell(f);
  if (size < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return -1; }
  char *buf = (char *)malloc((size_t)size + 1);
  if (!buf) { fclose(f); return -1; }
  size_t nread = fread(buf, 1, (size_t)size, f);
  fclose(f);
  if (nread != (size_t)size) { free(buf); return -1; }
  buf[size] = '\0';
  *out = buf;
  return size;
}

/* Walks package.path's .fnl analog (via package.searchpath) and compiles
 * the first matching .fnl through the embedded fennel module. */
static int dev_path_fennel_searcher(lua_State *L) {
  const char *modname = luaL_checkstring(L, 1);

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "path");
  const char *lua_path = lua_tostring(L, -1);
  if (!lua_path) {
    lua_pop(L, 2);
    lua_pushliteral(L, "\n\tpackage.path is not a string");
    return 1;
  }
  push_fnl_path(L, lua_path);
  lua_remove(L, -2); /* lua_path string */
  /* Stack: [modname, package, fnl_path] */

  lua_getfield(L, -2, "searchpath");
  lua_pushvalue(L, 1);
  lua_pushvalue(L, -3);
  if (lua_pcall(L, 2, 2, 0) != LUA_OK) {
    return lua_error(L);
  }
  /* Stack: [modname, package, fnl_path, found|nil, err|nil] */

  if (lua_isnil(L, -2)) {
    const char *err = lua_tostring(L, -1);
    lua_pushfstring(L, "\n%s", err ? err : "no fnl module");
    return 1;
  }

  const char *filepath = lua_tostring(L, -2);
  char *src = NULL;
  long size = slurp_file(filepath, &src);
  if (size < 0) {
    lua_pushfstring(L, "could not read '%s': %s", filepath, strerror(errno));
    return lua_error(L);
  }

  if (push_fennel_compile_string(L) < 0) {
    free(src);
    return lua_error(L);
  }

  char chunkname[PATH_MAX + 2];
  snprintf(chunkname, sizeof(chunkname), "@%s", filepath);

  lua_pushlstring(L, src, (size_t)size);
  free(src);
  lua_createtable(L, 0, 1);
  lua_pushstring(L, chunkname);
  lua_setfield(L, -2, "filename");

  if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
    return lua_error(L);
  }

  size_t compiled_len = 0;
  const char *compiled = lua_tolstring(L, -1, &compiled_len);
  if (!compiled) {
    lua_pushfstring(L, "fennel.compileString returned non-string for '%s'",
                    filepath);
    return lua_error(L);
  }
  if (luaL_loadbufferx(L, compiled, compiled_len, chunkname, "t") != LUA_OK) {
    return lua_error(L);
  }
  return 1;
}

/* Bootstrap the flat-extension searcher by deferring to fen.util.flat_extensions.
 *
 * After issue #67 Phase A, manifest-shaped first-party extensions live as
 * flat sources under <ext-root>/<kebab>/{manifest.fnl,init.fnl,...} with no
 * `fen/extensions/<snake>/` namespace mirror. The runtime contract still
 * uses `require :fen.extensions.<snake>...`, so when --extension-root is
 * given we ask the Fennel-side module to install a Lua searcher that maps
 * that namespace back to flat source and compiles via the fennel module.
 *
 * Logic lives in packages/util/src/fen/util/flat_extensions.fnl so the
 * same module powers the test runner (scripts/test/busted-helper.lua) and this
 * launcher. C just provides the roots and the slot. */
static int install_flat_extension_searcher(lua_State *L,
                                           const str_list *roots,
                                           int position) {
  if (roots->count == 0) return 0;

  lua_getglobal(L, "require");
  lua_pushstring(L, "fen.util.flat_extensions");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return -1;
  }

  lua_getfield(L, -1, "install!");
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 2);
    lua_pushliteral(L, "fen.util.flat_extensions.install! is not a function");
    return -1;
  }

  /* Build opts table: { roots = {...}, fennel = <mod>, position = N } */
  lua_createtable(L, 0, 3);

  lua_createtable(L, (int)roots->count, 0);
  for (size_t i = 0; i < roots->count; i++) {
    lua_pushstring(L, roots->items[i]);
    lua_seti(L, -2, (lua_Integer)(i + 1));
  }
  lua_setfield(L, -2, "roots");

  lua_getglobal(L, "require");
  lua_pushstring(L, "fennel");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    return -1;
  }
  lua_setfield(L, -2, "fennel");

  lua_pushinteger(L, position);
  lua_setfield(L, -2, "position");

  if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
    return -1;
  }
  lua_pop(L, 1); /* fen.util.flat_extensions module */
  return 0;
}

/* Mutate package.path / package.cpath so the standard Lua and C
 * searchers find files in --dev-path checkouts before falling back to
 * existing search paths and the embedded archive.
 *
 * Stack discipline: luaL_Buffer occupies one or more stack slots while
 * active, so we read package.path / package.cpath out into malloc'd
 * scratch first and only then start a buffer. */
static void prepend_dev_paths(lua_State *L, const str_list *paths) {
  if (paths->count == 0) return;

  lua_getglobal(L, "package");
  int pkg_idx = lua_gettop(L);

  /* package.path */
  lua_getfield(L, pkg_idx, "path");
  const char *existing_path = lua_tostring(L, -1);
  char *existing_path_copy = NULL;
  if (existing_path) {
    size_t l = strlen(existing_path);
    existing_path_copy = (char *)malloc(l + 1);
    memcpy(existing_path_copy, existing_path, l + 1);
  }
  lua_pop(L, 1);

  luaL_Buffer pb;
  luaL_buffinit(L, &pb);
  for (size_t i = 0; i < paths->count; i++) {
    luaL_addstring(&pb, paths->items[i]);
    luaL_addstring(&pb, "/?.lua;");
    luaL_addstring(&pb, paths->items[i]);
    luaL_addstring(&pb, "/?/init.lua;");
  }
  if (existing_path_copy) luaL_addstring(&pb, existing_path_copy);
  free(existing_path_copy);
  luaL_pushresult(&pb);
  lua_setfield(L, pkg_idx, "path");

  /* package.cpath */
  lua_getfield(L, pkg_idx, "cpath");
  const char *existing_cpath = lua_tostring(L, -1);
  char *existing_cpath_copy = NULL;
  if (existing_cpath) {
    size_t l = strlen(existing_cpath);
    existing_cpath_copy = (char *)malloc(l + 1);
    memcpy(existing_cpath_copy, existing_cpath, l + 1);
  }
  lua_pop(L, 1);

  luaL_Buffer cb;
  luaL_buffinit(L, &cb);
  for (size_t i = 0; i < paths->count; i++) {
    luaL_addstring(&cb, paths->items[i]);
    luaL_addstring(&cb, "/?.so;");
    luaL_addstring(&cb, paths->items[i]);
    luaL_addstring(&cb, "/?/init.so;");
  }
  if (existing_cpath_copy) luaL_addstring(&cb, existing_cpath_copy);
  free(existing_cpath_copy);
  luaL_pushresult(&cb);
  lua_setfield(L, pkg_idx, "cpath");

  lua_pop(L, 1); /* package */
}

/* --extension-root values are trusted flat first-party overlays for bundled
 * extension modules. Keep them separate from FEN_EXTENSIONS_PATH so Fennel-side
 * discovery can load those specs before untrusted user roots without recording
 * duplicate shadowed versions for the same on-disk directory. */
static void augment_extensions_env_named(const str_list *roots, const char *env_name) {
  if (roots->count == 0) return;
  const char *existing = getenv(env_name);
  size_t total = 0;
  for (size_t i = 0; i < roots->count; i++) {
    total += strlen(roots->items[i]) + 1;
  }
  if (existing && *existing) total += strlen(existing) + 1;
  char *combined = (char *)malloc(total + 1);
  if (!combined) return;
  size_t pos = 0;
  for (size_t i = 0; i < roots->count; i++) {
    size_t l = strlen(roots->items[i]);
    memcpy(combined + pos, roots->items[i], l);
    pos += l;
    if (i + 1 < roots->count || (existing && *existing)) {
      combined[pos++] = ':';
    }
  }
  if (existing && *existing) {
    size_t l = strlen(existing);
    memcpy(combined + pos, existing, l);
    pos += l;
  }
  combined[pos] = '\0';
  setenv(env_name, combined, 1);
  free(combined);
}

static void augment_extensions_env(const str_list *roots) {
  augment_extensions_env_named(roots, "FEN_FIRST_PARTY_EXTENSIONS_PATH");
}

/* Pull --dev-path / --extension-root flags out of argv (consumed by the
 * launcher; never seen by fen.main). Modifies argv in place by shifting
 * non-launcher entries down; returns the new argc. */
static int parse_overlay_flags(int argc, char **argv,
                               str_list *dev_paths, str_list *ext_roots) {
  int out = 1;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--dev-path") == 0 && i + 1 < argc) {
      str_list_push(dev_paths, argv[i + 1]);
      i++;
    } else if (strcmp(argv[i], "--extension-root") == 0 && i + 1 < argc) {
      str_list_push(ext_roots, argv[i + 1]);
      i++;
    } else {
      argv[out++] = argv[i];
    }
  }
  return out;
}

static void preload(lua_State *L, const char *name, lua_CFunction fn) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, fn);
  lua_setfield(L, -2, name);
  lua_pop(L, 2);
}

static void install_static_modules(lua_State *L) {
  preload(L, "cjson", luaopen_cjson);
  preload(L, "termbox2", luaopen_termbox2);
  preload(L, "fen_http", luaopen_fen_http);
  preload(L, "fen_process", luaopen_fen_process);
  preload(L, "fen_random", luaopen_fen_random);
  preload(L, "lfs", luaopen_lfs);
}

static void reset_package_paths(lua_State *L) {
  lua_getglobal(L, "package");
  lua_pushliteral(L, "./?.lua;./?/init.lua");
  lua_setfield(L, -2, "path");
  lua_pushliteral(L, "./?.so;./?/init.so");
  lua_setfield(L, -2, "cpath");
  lua_pop(L, 1);
}

static int install_searchers(lua_State *L) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchers");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 2);
    return luaL_error(L, "package.searchers is not a table");
  }

  lua_Integer n = luaL_len(L, -1);

  /* Shift existing [2..n] up by 1 to make room at slot 2 for the
   * dev-path Fennel overlay. */
  for (lua_Integer i = n + 1; i > 2; i--) {
    lua_geti(L, -1, i - 1);
    lua_seti(L, -2, i);
  }
  lua_pushcfunction(L, dev_path_fennel_searcher);
  lua_seti(L, -2, 2);

  /* Embedded archive searchers append after everything else, so user
   * LUA_PATH / LUA_CPATH plus dev-path mutations win over the floor. */
  lua_pushcfunction(L, embedded_zip_searcher);
  lua_seti(L, -2, n + 2);
  lua_pushcfunction(L, embedded_fennel_searcher);
  lua_seti(L, -2, n + 3);

  lua_pop(L, 2);
  return 0;
}

static void set_arg_table(lua_State *L, int argc, char **argv) {
  lua_createtable(L, argc > 1 ? argc - 1 : 0, 1);
  lua_pushstring(L, argv[0]);
  lua_seti(L, -2, 0);
  for (int i = 1; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_seti(L, -2, i);
  }
  lua_setglobal(L, "arg");
}

static char *self_path(void) {
  size_t cap = 4096;
  char *buf = NULL;
  while (cap <= (1 << 20)) {
    buf = (char *)realloc(buf, cap);
    if (!buf) {
      return NULL;
    }
    ssize_t n = readlink("/proc/self/exe", buf, cap - 1);
    if (n < 0) {
      free(buf);
      return NULL;
    }
    if ((size_t)n < cap - 1) {
      buf[n] = '\0';
      return buf;
    }
    cap *= 2;
  }
  free(buf);
  errno = ENAMETOOLONG;
  return NULL;
}

int main(int argc, char **argv) {
  char *exe = self_path();
  if (!exe) {
    fprintf(stderr, "fen: cannot locate /proc/self/exe: %s\n", strerror(errno));
    return 1;
  }

  int zip_err = 0;
  embedded_zip = zip_openwitherror(exe, 0, 'r', &zip_err);
  free(exe);
  if (!embedded_zip && argc > 0 && argv[0] && argv[0][0] == '/') {
    zip_err = 0;
    embedded_zip = zip_openwitherror(argv[0], 0, 'r', &zip_err);
  }
  if (!embedded_zip) {
    fprintf(stderr, "fen: cannot open embedded zip: %s\n", zip_strerror(zip_err));
    return 1;
  }

  /* Strip launcher-consumed overlay flags from argv before fen.main
   * sees them, then fold env-supplied paths into the same lists. */
  str_list dev_paths, ext_roots;
  str_list_init(&dev_paths);
  str_list_init(&ext_roots);
  argc = parse_overlay_flags(argc, argv, &dev_paths, &ext_roots);
  str_list_push_colon_split(&dev_paths, getenv("FEN_DEV_PATH"));
  str_list_push_colon_split(&ext_roots, getenv("FEN_EXTENSION_ROOT"));
  augment_extensions_env(&ext_roots);

  lua_State *L = luaL_newstate();
  if (!L) {
    fprintf(stderr, "fen: cannot allocate Lua state\n");
    str_list_free(&dev_paths);
    str_list_free(&ext_roots);
    zip_close(embedded_zip);
    return 1;
  }

  luaL_openlibs(L);
  reset_package_paths(L);
  install_static_modules(L);
  prepend_dev_paths(L, &dev_paths);
  set_arg_table(L, argc, argv);
  if (install_searchers(L) != 0) {
    fprintf(stderr, "fen: %s\n", lua_tostring(L, -1));
    lua_close(L);
    str_list_free(&dev_paths);
    str_list_free(&ext_roots);
    zip_close(embedded_zip);
    return 1;
  }

  /* Install the flat-extension searcher at slot 3 (after preload at 1
   * and dev-path-fennel at 2). Logic lives in fen.util.flat_extensions;
   * here we just hand it the configured roots and slot. No-op when no
   * --extension-root was given. */
  if (install_flat_extension_searcher(L, &ext_roots, 3) != 0) {
    fprintf(stderr, "fen: %s\n", lua_tostring(L, -1));
    lua_close(L);
    str_list_free(&dev_paths);
    str_list_free(&ext_roots);
    zip_close(embedded_zip);
    return 1;
  }

  lua_getglobal(L, "require");
  lua_pushstring(L, "fen.main");
  int rc = lua_pcall(L, 1, 0, 0);
  if (rc != LUA_OK) {
    fprintf(stderr, "fen: %s\n", lua_tostring(L, -1));
    lua_close(L);
    str_list_free(&dev_paths);
    str_list_free(&ext_roots);
    zip_close(embedded_zip);
    return 1;
  }

  lua_close(L);
  str_list_free(&dev_paths);
  str_list_free(&ext_roots);
  zip_close(embedded_zip);
  return 0;
}
