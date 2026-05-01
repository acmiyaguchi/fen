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

static struct zip_t *embedded_zip = NULL;

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

static int install_searcher(lua_State *L) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchers");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 2);
    return luaL_error(L, "package.searchers is not a table");
  }

  lua_Integer n = luaL_len(L, -1);
  for (lua_Integer i = n + 1; i > 2; i--) {
    lua_geti(L, -1, i - 1);
    lua_seti(L, -2, i);
  }
  lua_pushcfunction(L, embedded_zip_searcher);
  lua_seti(L, -2, 2);
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
    fprintf(stderr, "fen-single: cannot locate /proc/self/exe: %s\n", strerror(errno));
    return 1;
  }

  int zip_err = 0;
  embedded_zip = zip_openwitherror(exe, 0, 'r', &zip_err);
  free(exe);
  if (!embedded_zip) {
    fprintf(stderr, "fen-single: cannot open embedded zip: %s\n", zip_strerror(zip_err));
    return 1;
  }

  lua_State *L = luaL_newstate();
  if (!L) {
    fprintf(stderr, "fen-single: cannot allocate Lua state\n");
    zip_close(embedded_zip);
    return 1;
  }

  luaL_openlibs(L);
  set_arg_table(L, argc, argv);
  if (install_searcher(L) != 0) {
    fprintf(stderr, "fen-single: %s\n", lua_tostring(L, -1));
    lua_close(L);
    zip_close(embedded_zip);
    return 1;
  }

  lua_getglobal(L, "require");
  lua_pushstring(L, "fen.main");
  int rc = lua_pcall(L, 1, 0, 0);
  if (rc != LUA_OK) {
    fprintf(stderr, "fen-single: %s\n", lua_tostring(L, -1));
    lua_close(L);
    zip_close(embedded_zip);
    return 1;
  }

  lua_close(L);
  zip_close(embedded_zip);
  return 0;
}
