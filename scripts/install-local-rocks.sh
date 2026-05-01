#!/bin/sh
set -eu

LUAROCKS=${LUAROCKS:-luarocks}
FENNEL=${FENNEL:-fennel}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TREE=${FEN_LOCAL_ROCKS_TREE:-$ROOT/lua_modules}

rocks=$(
  {
    find "$ROOT/packages/util" -maxdepth 1 -name '*.rockspec' -type f 2>/dev/null
    find "$ROOT/packages/core" -maxdepth 1 -name '*.rockspec' -type f 2>/dev/null
    find "$ROOT/packages/providers" "$ROOT/packages/extensions" -mindepth 2 -maxdepth 2 -name '*.rockspec' -type f 2>/dev/null | sort
    find "$ROOT/packages/fen" -maxdepth 1 -name '*.rockspec' -type f 2>/dev/null
  } | sed "s#^$ROOT/##"
)

for rock in $rocks; do
  d=${rock%/*}
  base=${rock##*/}
  echo "$LUAROCKS make $rock"
  (
    PATH="$TREE/bin:$PATH"
    LUA_PATH="$TREE/share/lua/5.4/?.lua;$TREE/share/lua/5.4/?/init.lua;${LUA_PATH:-}"
    LUA_CPATH="$TREE/lib/lua/5.4/?.so;${LUA_CPATH:-}"
    export PATH LUA_PATH LUA_CPATH
    export FEN_WORKSPACE="$ROOT" FENNEL
    cd "$ROOT/$d"
    "$LUAROCKS" --tree="$TREE" make --deps-mode=all "$base" \
      LUA_INCDIR="${LUA_INCDIR:-}" \
      CURL_INCDIR="${CURL_INCDIR:-}" \
      CURL_LIBDIR="${CURL_LIBDIR:-}"
  )
done

PATH="$TREE/bin:$PATH" \
LUA_PATH="$TREE/share/lua/5.4/?.lua;$TREE/share/lua/5.4/?/init.lua;;" \
LUA_CPATH="$TREE/lib/lua/5.4/?.so;;" \
  fen --help >/dev/null

echo 'local LuaRocks install OK.'
