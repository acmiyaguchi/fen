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
if [ ! -f packages/util/dist/fen_http.so ] || \
   [ ! -f packages/util/dist/fen_process.so ] || \
   [ ! -f packages/util/dist/fen_random.so ] || \
   [ ! -f extensions/tui/dist/termbox2.so ]; then
  CC=${CC:-cc}
  CFLAGS=${CFLAGS:-"-O2 -fPIC -Wall"}
  LUA_INCDIR=${LUA_INCDIR:-/usr/include/lua5.4}
  CURL_INCDIR=${CURL_INCDIR:-}
  CURL_LIBDIR=${CURL_LIBDIR:-}

  TERMBOX_SO=extensions/tui/dist/termbox2.so
  FEN_HTTP_SO=packages/util/dist/fen_http.so
  FEN_PROCESS_SO=packages/util/dist/fen_process.so
  FEN_RANDOM_SO=packages/util/dist/fen_random.so

  mkdir -p "$(dirname "$TERMBOX_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    -Iextensions/tui/vendor \
    -shared extensions/tui/vendor/lua_termbox2.c \
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
fi

if [ "$#" -gt 0 ]; then
  exec busted --loaders=lua,fennel --helper=scripts/busted-helper.lua --pattern=_test "$@"
else
  exec busted --loaders=lua,fennel --helper=scripts/busted-helper.lua --pattern=_test packages extensions
fi
