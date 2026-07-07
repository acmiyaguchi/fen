#!/bin/sh
set -eu

missing=0
for cmd in fennel busted; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "run-tests: missing $cmd" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "run-tests: install dev deps (for example: nix develop, or luarocks --lua-version=5.4 install fennel busted lua-cjson luasocket luafilesystem)" >&2
  exit 127
fi

# Tests exercise native helpers directly (fen_http.so) and indirectly via
# cooperative bash/process I/O (fen_process.so). Keep this script self-contained
# so `make test` works from a source checkout after `make clean` / without a
# prior Nix build step.
need_pty=0
case " ${FEN_BUILD_PTY_HELPER:-} ${FEN_INCLUDE_SMOKE_TESTS:-0} $* " in
  *" 1 "*|*"extensions/adapters/presenters/tui/tests/smoke/pty_test.fnl"*) need_pty=1 ;;
esac

if [ ! -f packages/util/dist/fen_http.so ] || \
   [ ! -f packages/util/dist/fen_process.so ] || \
   [ ! -f packages/util/dist/fen_random.so ] || \
   { [ "$need_pty" -eq 1 ] && [ ! -f packages/testing/dist/fen_pty.so ]; } || \
   [ ! -f extensions/adapters/presenters/tui/dist/termbox2.so ]; then
  CC=${CC:-cc}
  CFLAGS=${CFLAGS:-"-O2 -fPIC -Wall"}
  LUA_INCDIR=${LUA_INCDIR:-/usr/include/lua5.4}
  CURL_INCDIR=${CURL_INCDIR:-}
  CURL_LIBDIR=${CURL_LIBDIR:-}

  TERMBOX_SO=extensions/adapters/presenters/tui/dist/termbox2.so
  FEN_HTTP_SO=packages/util/dist/fen_http.so
  FEN_PROCESS_SO=packages/util/dist/fen_process.so
  FEN_RANDOM_SO=packages/util/dist/fen_random.so
  FEN_PTY_SO=packages/testing/dist/fen_pty.so

  mkdir -p "$(dirname "$TERMBOX_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    -Iextensions/adapters/presenters/tui/vendor \
    -shared extensions/adapters/presenters/tui/vendor/lua_termbox2.c \
    -o "$TERMBOX_SO"

  mkdir -p "$(dirname "$FEN_HTTP_SO")"
  CURL_INC_FLAG=
  CURL_LIB_FLAG=
  if [ -n "$CURL_INCDIR" ]; then
    CURL_INC_FLAG="-I$CURL_INCDIR"
  fi
  if [ -n "$CURL_LIBDIR" ]; then
    CURL_LIB_FLAG="-L$CURL_LIBDIR"
  fi
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    $CURL_INC_FLAG \
    -shared packages/util/vendor/fen_http.c \
    $CURL_LIB_FLAG \
    -lcurl \
    -o "$FEN_HTTP_SO"

  mkdir -p "$(dirname "$FEN_PROCESS_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    -shared packages/util/vendor/fen_process.c \
    -o "$FEN_PROCESS_SO"

  mkdir -p "$(dirname "$FEN_RANDOM_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    -shared packages/util/vendor/fen_random.c \
    -o "$FEN_RANDOM_SO"

  if [ "$need_pty" -eq 1 ]; then
    mkdir -p "$(dirname "$FEN_PTY_SO")"
    # shellcheck disable=SC2086
    $CC $CFLAGS \
      -I"$LUA_INCDIR" \
      -shared packages/testing/vendor/fen_pty.c \
      -lutil \
      -o "$FEN_PTY_SO"
  fi
fi

exec_busted() {
  # BUSTED_ARGS is intentionally shell-split so maintainers can pass normal
  # busted options such as BUSTED_ARGS='--filter=foo --shuffle'. Keep test
  # paths in TESTS/positional args when they may contain shell metacharacters.
  if [ -n "${BUSTED_ARGS:-}" ]; then
    # shellcheck disable=SC2086
    exec busted --loaders=lua,fennel --helper=scripts/test/busted-helper.lua --pattern=_test $BUSTED_ARGS "$@"
  else
    exec busted --loaders=lua,fennel --helper=scripts/test/busted-helper.lua --pattern=_test "$@"
  fi
}

exec_test_roots() {
  # Keep directory-focused runs aligned with default `make test`: a directory
  # root such as TESTS=extensions/adapters/presenters/tui/tests should not
  # accidentally pick up opt-in smoke tests. Explicit smoke files still run.
  if [ "${FEN_INCLUDE_SMOKE_TESTS:-0}" = 1 ]; then
    exec_busted "$@"
  fi

  expanded=
  for root do
    if [ -d "$root" ]; then
      found=$(find "$root" -type f -name '*_test.fnl' ! -path '*/tests/smoke/*' | sort)
      if [ -n "$found" ]; then
        expanded="$expanded $found"
      fi
    else
      expanded="$expanded $root"
    fi
  done

  if [ -n "$expanded" ]; then
    # shellcheck disable=SC2086
    exec_busted $expanded
  else
    exec_busted "$@"
  fi
}

if [ "$#" -gt 0 ]; then
  exec_test_roots "$@"
else
  # Keep opt-in smoke suites (notably the real-PTY TUI smoke) out of the
  # ordinary unit/integration pass; dedicated make targets pass those files
  # explicitly and enable any extra native helpers they need.
  if [ "${FEN_INCLUDE_SMOKE_TESTS:-0}" = 1 ]; then
    tests=$(find packages extensions -type f -name '*_test.fnl' | sort)
  else
    tests=$(find packages extensions -type f -name '*_test.fnl' ! -path '*/tests/smoke/*' | sort)
  fi
  # shellcheck disable=SC2086
  exec_busted $tests
fi
