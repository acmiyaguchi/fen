/* Tiny process/pipe helpers for fen.util.process.
 *
 * Replaces the small luaposix surface fen used for cooperative popen reads:
 * fileno(FILE*), fcntl(O_NONBLOCK), read(2), and EAGAIN. Kept project-owned
 * so the single-file artifact can statically register it without carrying the
 * whole luaposix rock.
 *
 * Also provides a small POSIX subprocess surface used by timed/cancellable
 * command runners. The subprocess API intentionally stays Unix-oriented:
 * fen targets Linux/macOS-like systems and ARMv7 Raspberry-Pi-class hardware.
 */

#include <errno.h>
#include <fcntl.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef LUA_FILEHANDLE
#define LUA_FILEHANDLE "FILE*"
#endif

static FILE *check_file(lua_State *L, int idx) {
  luaL_Stream *p = (luaL_Stream *)luaL_checkudata(L, idx, LUA_FILEHANDLE);
  luaL_argcheck(L, p != NULL && p->f != NULL, idx, "closed file");
  return p->f;
}

static void push_errno(lua_State *L) {
  lua_pushnil(L);
  lua_pushstring(L, strerror(errno));
  lua_pushinteger(L, errno);
}

static int set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int set_nonblock_fd(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void sleep_ms_int(long ms) {
  if (ms <= 0) return;
  struct timespec req;
  req.tv_sec = ms / 1000;
  req.tv_nsec = (ms % 1000) * 1000000L;
  while (nanosleep(&req, &req) < 0 && errno == EINTR) {
  }
}

static int l_fileno(lua_State *L) {
  FILE *f = check_file(L, 1);
  int fd = fileno(f);
  if (fd < 0) {
    push_errno(L);
    return 3;
  }
  lua_pushinteger(L, fd);
  return 1;
}

static int l_set_nonblock(lua_State *L) {
  int fd = (int)luaL_checkinteger(L, 1);
  if (set_nonblock_fd(fd) < 0) {
    push_errno(L);
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
  push_errno(L);
  return 3;
}

static int l_close_fd(lua_State *L) {
  int fd = (int)luaL_checkinteger(L, 1);
  if (close(fd) < 0) {
    /* On Linux, close() may already have consumed the fd when EINTR is
     * reported. Retrying could close an unrelated future fd, so treat EINTR
     * as closed for cleanup purposes. */
    if (errno == EINTR) {
      lua_pushboolean(L, 1);
      return 1;
    }
    push_errno(L);
    return 3;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int l_sleep_ms(lua_State *L) {
  long ms = (long)luaL_optinteger(L, 1, 0);
  sleep_ms_int(ms);
  lua_pushboolean(L, 1);
  return 1;
}

static int l_monotonic_ms(lua_State *L) {
#ifdef CLOCK_MONOTONIC
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
    lua_pushinteger(L, (lua_Integer)ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
    return 1;
  }
#endif
  struct timeval tv;
  if (gettimeofday(&tv, NULL) == 0) {
    lua_pushinteger(L, (lua_Integer)tv.tv_sec * 1000 + tv.tv_usec / 1000);
    return 1;
  }
  push_errno(L);
  return 3;
}

static int l_spawn_shell(lua_State *L) {
  const char *cmd = luaL_checkstring(L, 1);
  const char *cwd = NULL;
  if (!lua_isnoneornil(L, 2)) {
    cwd = luaL_checkstring(L, 2);
    if (cwd[0] == '\0') cwd = NULL;
  }

  int pipefd[2];
  if (pipe(pipefd) < 0) {
    push_errno(L);
    return 3;
  }
  if (set_cloexec(pipefd[0]) < 0 || set_cloexec(pipefd[1]) < 0) {
    int saved = errno;
    close(pipefd[0]);
    close(pipefd[1]);
    errno = saved;
    push_errno(L);
    return 3;
  }

  pid_t pid = fork();
  if (pid < 0) {
    int saved = errno;
    close(pipefd[0]);
    close(pipefd[1]);
    errno = saved;
    push_errno(L);
    return 3;
  }

  if (pid == 0) {
    /* Child. Avoid touching Lua state after fork. */
    close(pipefd[0]);

    if (setsid() < 0) _exit(126);
    if (cwd && chdir(cwd) < 0) _exit(126);

    int devnull = open("/dev/null", O_RDONLY);
    if (devnull >= 0) {
      (void)dup2(devnull, STDIN_FILENO);
      if (devnull != STDIN_FILENO) close(devnull);
    } else {
      close(STDIN_FILENO);
    }

    if (dup2(pipefd[1], STDOUT_FILENO) < 0) _exit(126);
    if (dup2(pipefd[1], STDERR_FILENO) < 0) _exit(126);
    if (pipefd[1] != STDOUT_FILENO && pipefd[1] != STDERR_FILENO) {
      close(pipefd[1]);
    }

    execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
    _exit(127);
  }

  close(pipefd[1]);
  if (set_nonblock_fd(pipefd[0]) < 0) {
    int saved = errno;
    close(pipefd[0]);
    (void)kill(-pid, SIGKILL);
    (void)kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
    }
    errno = saved;
    push_errno(L);
    return 3;
  }

  lua_newtable(L);
  lua_pushinteger(L, (lua_Integer)pid);
  lua_setfield(L, -2, "pid");
  lua_pushinteger(L, pipefd[0]);
  lua_setfield(L, -2, "fd");
  return 1;
}

static int l_wait_pid(lua_State *L) {
  pid_t pid = (pid_t)luaL_checkinteger(L, 1);
  int nohang = lua_toboolean(L, 2);
  int status = 0;
  pid_t r;
  do {
    r = waitpid(pid, &status, nohang ? WNOHANG : 0);
  } while (r < 0 && errno == EINTR);

  if (r < 0) {
    push_errno(L);
    return 3;
  }
  if (r == 0) {
    lua_pushboolean(L, 1);
    lua_pushliteral(L, "running");
    return 2;
  }
  if (WIFEXITED(status)) {
    lua_pushboolean(L, 1);
    lua_pushliteral(L, "exit");
    lua_pushinteger(L, WEXITSTATUS(status));
    return 3;
  }
  if (WIFSIGNALED(status)) {
    lua_pushboolean(L, 1);
    lua_pushliteral(L, "signal");
    lua_pushinteger(L, WTERMSIG(status));
    return 3;
  }
  lua_pushboolean(L, 1);
  lua_pushliteral(L, "other");
  lua_pushinteger(L, status);
  return 3;
}

static int l_kill_process_group(lua_State *L) {
  pid_t pid = (pid_t)luaL_checkinteger(L, 1);
  int sig = (int)luaL_checkinteger(L, 2);
  if (pid <= 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "invalid pid");
    lua_pushinteger(L, EINVAL);
    return 3;
  }
  if (kill(-pid, sig) == 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  int group_errno = errno;
  if (kill(pid, sig) == 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (group_errno == ESRCH && errno == ESRCH) {
    lua_pushboolean(L, 1);
    return 1;
  }
  errno = group_errno;
  push_errno(L);
  return 3;
}

static const luaL_Reg lib[] = {
    {"fileno", l_fileno},
    {"set_nonblock", l_set_nonblock},
    {"read", l_read},
    {"close_fd", l_close_fd},
    {"sleep_ms", l_sleep_ms},
    {"monotonic_ms", l_monotonic_ms},
    {"spawn_shell", l_spawn_shell},
    {"wait_pid", l_wait_pid},
    {"kill_process_group", l_kill_process_group},
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
  lua_pushinteger(L, SIGTERM);
  lua_setfield(L, -2, "SIGTERM");
  lua_pushinteger(L, SIGKILL);
  lua_setfield(L, -2, "SIGKILL");
  return 1;
}
