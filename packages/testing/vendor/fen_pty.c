/* Test-only PTY helper for fen.testing.pty.
 *
 * This module is intentionally not embedded into the shipped fen binary. It is
 * loaded by opt-in smoke/integration tests that need to run fen under a real
 * pseudo-terminal.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define FEN_PTY_HANDLE "fen_pty.handle"

typedef struct {
  int fd;
  pid_t pid;
  int reaped;
  int status;
} fen_pty_handle;

static fen_pty_handle *check_handle(lua_State *L, int idx) {
  fen_pty_handle *h = (fen_pty_handle *)luaL_checkudata(L, idx, FEN_PTY_HANDLE);
  luaL_argcheck(L, h != NULL, idx, "invalid PTY handle");
  return h;
}

static char **argv_from_table(lua_State *L, int idx, int *argc_out) {
  luaL_checktype(L, idx, LUA_TTABLE);
  lua_Integer n = luaL_len(L, idx);
  luaL_argcheck(L, n > 0, idx, "argv must not be empty");
  char **argv = (char **)calloc((size_t)n + 1, sizeof(char *));
  if (!argv) luaL_error(L, "calloc argv failed");
  for (lua_Integer i = 1; i <= n; i++) {
    lua_geti(L, idx, i);
    const char *s = luaL_checkstring(L, -1);
    argv[i - 1] = strdup(s);
    lua_pop(L, 1);
    if (!argv[i - 1]) luaL_error(L, "strdup argv failed");
  }
  argv[n] = NULL;
  if (argc_out) *argc_out = (int)n;
  return argv;
}

static void free_argv(char **argv) {
  if (!argv) return;
  for (char **p = argv; *p; p++) free(*p);
  free(argv);
}

static void apply_env(lua_State *L, int idx) {
  if (lua_isnoneornil(L, idx)) return;
  luaL_checktype(L, idx, LUA_TTABLE);
  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    const char *key = luaL_checkstring(L, -2);
    if (lua_isboolean(L, -1) && !lua_toboolean(L, -1)) {
      unsetenv(key);
    } else if (!lua_isnil(L, -1)) {
      const char *val = luaL_tolstring(L, -1, NULL);
      setenv(key, val, 1);
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
}

static int wait_maybe(fen_pty_handle *h, int flags) {
  if (h->pid <= 0 || h->reaped) return 0;
  int status = 0;
  pid_t r = waitpid(h->pid, &status, flags);
  if (r == h->pid) {
    h->status = status;
    h->reaped = 1;
    return 1;
  }
  return 0;
}

static void push_status(lua_State *L, fen_pty_handle *h) {
  lua_newtable(L);
  lua_pushboolean(L, h->reaped);
  lua_setfield(L, -2, "exited");
  if (h->reaped) {
    if (WIFEXITED(h->status)) {
      lua_pushinteger(L, WEXITSTATUS(h->status));
      lua_setfield(L, -2, "code");
    }
    if (WIFSIGNALED(h->status)) {
      lua_pushinteger(L, WTERMSIG(h->status));
      lua_setfield(L, -2, "signal");
    }
  }
}

static int h_read(lua_State *L) {
  fen_pty_handle *h = check_handle(L, 1);
  int timeout_ms = (int)luaL_optinteger(L, 2, 1000);
  size_t max_bytes = (size_t)luaL_optinteger(L, 3, 4096);
  if (max_bytes < 1) max_bytes = 1;
  if (h->fd < 0) {
    lua_pushnil(L); lua_pushliteral(L, "closed"); return 2;
  }
  struct pollfd pfd;
  pfd.fd = h->fd;
  pfd.events = POLLIN | POLLHUP | POLLERR;
  pfd.revents = 0;
  int pr = poll(&pfd, 1, timeout_ms);
  if (pr == 0) { lua_pushnil(L); lua_pushliteral(L, "timeout"); return 2; }
  if (pr < 0) { lua_pushnil(L); lua_pushstring(L, strerror(errno)); lua_pushinteger(L, errno); return 3; }
  char *buf = (char *)lua_newuserdatauv(L, max_bytes, 0);
  ssize_t n = read(h->fd, buf, max_bytes);
  if (n > 0) { lua_pushlstring(L, buf, (size_t)n); return 1; }
  if (n == 0 || errno == EIO) { lua_pushliteral(L, ""); return 1; }
  lua_pushnil(L); lua_pushstring(L, strerror(errno)); lua_pushinteger(L, errno); return 3;
}

static int h_write(lua_State *L) {
  fen_pty_handle *h = check_handle(L, 1);
  size_t len = 0;
  const char *s = luaL_checklstring(L, 2, &len);
  if (h->fd < 0) { lua_pushnil(L); lua_pushliteral(L, "closed"); return 2; }
  ssize_t n = write(h->fd, s, len);
  if (n >= 0) { lua_pushinteger(L, n); return 1; }
  lua_pushnil(L); lua_pushstring(L, strerror(errno)); lua_pushinteger(L, errno); return 3;
}

static int h_resize(lua_State *L) {
  fen_pty_handle *h = check_handle(L, 1);
  int cols = (int)luaL_checkinteger(L, 2);
  int rows = (int)luaL_checkinteger(L, 3);
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)cols;
  ws.ws_row = (unsigned short)rows;
  if (ioctl(h->fd, TIOCSWINSZ, &ws) == 0) { lua_pushboolean(L, 1); return 1; }
  lua_pushnil(L); lua_pushstring(L, strerror(errno)); lua_pushinteger(L, errno); return 3;
}

static int h_wait(lua_State *L) {
  fen_pty_handle *h = check_handle(L, 1);
  int timeout_ms = (int)luaL_optinteger(L, 2, 0);
  int slept = 0;
  while (!h->reaped) {
    if (wait_maybe(h, WNOHANG)) break;
    if (slept >= timeout_ms) {
      lua_pushnil(L); lua_pushliteral(L, "timeout"); return 2;
    }
    usleep(10000);
    slept += 10;
  }
  push_status(L, h);
  return 1;
}

static int h_kill(lua_State *L) {
  fen_pty_handle *h = check_handle(L, 1);
  int sig = (int)luaL_optinteger(L, 2, SIGTERM);
  if (h->pid > 0 && !h->reaped) kill(h->pid, sig);
  lua_pushboolean(L, 1);
  return 1;
}

static int h_close(lua_State *L) {
  fen_pty_handle *h = check_handle(L, 1);
  if (h->fd >= 0) { close(h->fd); h->fd = -1; }
  if (h->pid > 0 && !h->reaped) {
    if (!wait_maybe(h, WNOHANG)) {
      kill(h->pid, SIGTERM);
      usleep(50000);
      if (!wait_maybe(h, WNOHANG)) kill(h->pid, SIGKILL);
      wait_maybe(h, 0);
    }
  }
  return 0;
}

static int l_spawn(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "argv");
  int argc = 0;
  char **argv = argv_from_table(L, -1, &argc);
  lua_pop(L, 1);

  int cols = 80, rows = 24;
  lua_getfield(L, 1, "cols"); if (!lua_isnil(L, -1)) cols = (int)luaL_checkinteger(L, -1); lua_pop(L, 1);
  lua_getfield(L, 1, "rows"); if (!lua_isnil(L, -1)) rows = (int)luaL_checkinteger(L, -1); lua_pop(L, 1);

  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)cols;
  ws.ws_row = (unsigned short)rows;

  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);
  if (pid < 0) {
    int e = errno;
    free_argv(argv);
    lua_pushnil(L); lua_pushstring(L, strerror(e)); lua_pushinteger(L, e); return 3;
  }
  if (pid == 0) {
    lua_getfield(L, 1, "cwd");
    if (!lua_isnil(L, -1) && chdir(lua_tostring(L, -1)) != 0) _exit(126);
    lua_pop(L, 1);
    lua_getfield(L, 1, "env");
    apply_env(L, lua_gettop(L));
    lua_pop(L, 1);
    execvp(argv[0], argv);
    _exit(127);
  }

  free_argv(argv);
  fen_pty_handle *h = (fen_pty_handle *)lua_newuserdatauv(L, sizeof(fen_pty_handle), 0);
  h->fd = master;
  h->pid = pid;
  h->reaped = 0;
  h->status = 0;
  luaL_getmetatable(L, FEN_PTY_HANDLE);
  lua_setmetatable(L, -2);
  return 1;
}

static const luaL_Reg handle_methods[] = {
  {"read", h_read}, {"write", h_write}, {"resize", h_resize},
  {"wait", h_wait}, {"kill", h_kill}, {"close", h_close},
  {NULL, NULL},
};

static const luaL_Reg lib[] = {{"spawn", l_spawn}, {NULL, NULL}};

int luaopen_fen_pty(lua_State *L) {
  luaL_newmetatable(L, FEN_PTY_HANDLE);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, h_close);
  lua_setfield(L, -2, "__gc");
  luaL_setfuncs(L, handle_methods, 0);
  lua_pop(L, 1);
  luaL_newlib(L, lib);
  return 1;
}
