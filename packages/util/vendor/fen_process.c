/* Tiny process/pipe helpers for fen.util.process.
 *
 * Replaces the small luaposix surface fen used for cooperative popen reads:
 * fileno(FILE*), fcntl(O_NONBLOCK), read(2), and EAGAIN. Kept project-owned
 * so the single-file artifact can statically register it without carrying the
 * whole luaposix rock.
 */

#include <errno.h>
#include <fcntl.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef LUA_FILEHANDLE
#define LUA_FILEHANDLE "FILE*"
#endif

static FILE *check_file(lua_State *L, int idx) {
  luaL_Stream *p = (luaL_Stream *)luaL_checkudata(L, idx, LUA_FILEHANDLE);
  luaL_argcheck(L, p != NULL && p->f != NULL, idx, "closed file");
  return p->f;
}

static int l_fileno(lua_State *L) {
  FILE *f = check_file(L, 1);
  int fd = fileno(f);
  if (fd < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    lua_pushinteger(L, errno);
    return 3;
  }
  lua_pushinteger(L, fd);
  return 1;
}

static int l_set_nonblock(lua_State *L) {
  int fd = (int)luaL_checkinteger(L, 1);
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    lua_pushinteger(L, errno);
    return 3;
  }
  if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    lua_pushinteger(L, errno);
    return 3;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int l_read(lua_State *L) {
  int fd = (int)luaL_checkinteger(L, 1);
  size_t size = (size_t)luaL_optinteger(L, 2, 4096);
  char *buf = (char *)lua_newuserdatauv(L, size > 0 ? size : 1, 0);
  ssize_t n = read(fd, buf, size);
  if (n >= 0) {
    lua_pushlstring(L, buf, (size_t)n);
    return 1;
  }
  lua_pushnil(L);
  lua_pushstring(L, strerror(errno));
  lua_pushinteger(L, errno);
  return 3;
}

static const luaL_Reg lib[] = {
    {"fileno", l_fileno},
    {"set_nonblock", l_set_nonblock},
    {"read", l_read},
    {NULL, NULL},
};

int luaopen_fen_process(lua_State *L) {
  luaL_newlib(L, lib);
  lua_pushinteger(L, EAGAIN);
  lua_setfield(L, -2, "EAGAIN");
#ifdef EWOULDBLOCK
  lua_pushinteger(L, EWOULDBLOCK);
  lua_setfield(L, -2, "EWOULDBLOCK");
#endif
  return 1;
}
