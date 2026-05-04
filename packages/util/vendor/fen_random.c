/* Project-owned cryptographic-RNG binding for fen.util.random.
 *
 * Exposes a single Lua function:
 *
 *   fen_random.bytes(n) -> string of `n` raw bytes from the OS CSPRNG
 *
 * Why a native module instead of /dev/urandom in pure Lua: we want the
 * source to remain portable to macOS and Windows even though the canonical
 * artifact is Linux musl-static. Each platform has its own preferred
 * crypto-RNG API; the #ifdef dispatch below is the smallest delta that
 * keeps the source building everywhere.
 *
 *   Linux  : getrandom(2) (no glibc symbol — works under musl-static),
 *            with a /dev/urandom fallback if getrandom is unavailable.
 *   macOS  : arc4random_buf(3) — always available since 10.7.
 *   Windows: BCryptGenRandom from bcrypt.lib.
 *
 * The function is called once per Codex login (32 bytes for the PKCE
 * verifier), so performance is irrelevant — correctness and portability
 * are everything. */

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <stddef.h>
#include <string.h>

#define FEN_RANDOM_MAX 4096

#if defined(_WIN32)
  #include <windows.h>
  #include <bcrypt.h>
  #ifndef STATUS_SUCCESS
    #define STATUS_SUCCESS ((NTSTATUS)0x00000000L)
  #endif
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
  #include <stdlib.h>
#elif defined(__linux__)
  #include <errno.h>
  #include <fcntl.h>
  #include <sys/syscall.h>
  #include <unistd.h>
  #if defined(__has_include)
    #if __has_include(<sys/random.h>)
      #include <sys/random.h>
      #define FEN_RANDOM_HAVE_GETRANDOM_HEADER 1
    #endif
  #endif
#else
  #include <fcntl.h>
  #include <unistd.h>
#endif

static int fill_random(void *buf, size_t n, const char **err) {
#if defined(_WIN32)
  NTSTATUS rc = BCryptGenRandom(NULL, (PUCHAR)buf, (ULONG)n,
                                BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if (rc != STATUS_SUCCESS) {
    *err = "BCryptGenRandom failed";
    return -1;
  }
  return 0;
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
  arc4random_buf(buf, n);
  return 0;
#elif defined(__linux__)
  size_t off = 0;
  while (off < n) {
    long rc;
  #if defined(FEN_RANDOM_HAVE_GETRANDOM_HEADER)
    rc = (long)getrandom((unsigned char *)buf + off, n - off, 0);
  #elif defined(SYS_getrandom)
    rc = syscall(SYS_getrandom, (unsigned char *)buf + off, n - off, 0);
  #else
    rc = -1;
    errno = ENOSYS;
  #endif
    if (rc < 0) {
      if (errno == EINTR) continue;
      /* Fall back to /dev/urandom when getrandom is unavailable. */
      int fd = open("/dev/urandom", O_RDONLY);
      if (fd < 0) {
        *err = "no entropy source available (getrandom + /dev/urandom both failed)";
        return -1;
      }
      while (off < n) {
        ssize_t r = read(fd, (unsigned char *)buf + off, n - off);
        if (r < 0) {
          if (errno == EINTR) continue;
          close(fd);
          *err = "read /dev/urandom failed";
          return -1;
        }
        if (r == 0) {
          close(fd);
          *err = "/dev/urandom unexpected EOF";
          return -1;
        }
        off += (size_t)r;
      }
      close(fd);
      return 0;
    }
    off += (size_t)rc;
  }
  return 0;
#else
  /* Generic POSIX fallback. */
  int fd = open("/dev/urandom", O_RDONLY);
  if (fd < 0) {
    *err = "open /dev/urandom failed";
    return -1;
  }
  size_t off = 0;
  while (off < n) {
    ssize_t r = read(fd, (unsigned char *)buf + off, n - off);
    if (r < 0) {
      close(fd);
      *err = "read /dev/urandom failed";
      return -1;
    }
    if (r == 0) {
      close(fd);
      *err = "/dev/urandom unexpected EOF";
      return -1;
    }
    off += (size_t)r;
  }
  close(fd);
  return 0;
#endif
}

static int l_bytes(lua_State *L) {
  lua_Integer n = luaL_checkinteger(L, 1);
  if (n <= 0) {
    return luaL_error(L, "fen_random.bytes: n must be positive (got %I)", n);
  }
  if (n > FEN_RANDOM_MAX) {
    return luaL_error(L, "fen_random.bytes: n exceeds FEN_RANDOM_MAX (%d)",
                      FEN_RANDOM_MAX);
  }
  unsigned char buf[FEN_RANDOM_MAX];
  const char *err = NULL;
  if (fill_random(buf, (size_t)n, &err) != 0) {
    return luaL_error(L, "fen_random.bytes: %s", err ? err : "unknown error");
  }
  lua_pushlstring(L, (const char *)buf, (size_t)n);
  return 1;
}

static const luaL_Reg lib[] = {
    {"bytes", l_bytes},
    {NULL, NULL},
};

int luaopen_fen_random(lua_State *L) {
  luaL_newlib(L, lib);
  return 1;
}
