#!/bin/sh
# package-lua-tree.sh — compile/stage the Lua tree embedded in the single-file
# fen binary. This is the shared packaging spine for both the Nix build and the
# non-Nix `make fen` path: callers supply already-resolved dependency paths via
# environment variables, and this script owns the module tree shape and optional
# deterministic ZIP creation. POSIX sh only.
#
# Usage:
#   FENNEL=fennel \
#   FENNEL_LUA=/path/to/fennel.lua \
#   DKJSON_LUA=/path/to/dkjson.lua \
#   LUASOCKET_SRC=/path/to/luasocket/src \
#   FEN_VERSION=... ARTIFACT_SYSTEM=... \
#   [LUAROCKS_SRC=/path/to/share/lua/5.4/luarocks] \
#   [ZIPCMD=zip FEN_ZIP_OUT=/path/to/fen-lua.zip] \
#   sh scripts/build/package-lua-tree.sh <root>
set -eu

ROOT=${1:?usage: package-lua-tree.sh <root>}
: "${FENNEL:?}" "${FENNEL_LUA:?}" "${DKJSON_LUA:?}" "${LUASOCKET_SRC:?}"
: "${FEN_VERSION:?}" "${ARTIFACT_SYSTEM:?}"

# 1. Compile every .fnl to its package dist/ tree.
"$FENNEL" scripts/build/fennel-build.fnl

# 2. Stamp version (consumed by fen.version / `fen --version`, `/status`).
mkdir -p packages/fen/dist/fen
cat > packages/fen/dist/fen/version.lua <<EOF
return {
  version = "${FEN_VERSION}",
  gitRev = "${FEN_GIT_REV:-}",
  gitShortRev = "${FEN_GIT_SHORT:-}",
  dirty = ${FEN_DIRTY:-false},
  source = "${FEN_BUILD_SOURCE:-make}",
  lastModified = "${FEN_LAST_MODIFIED:-}",
  buildSystem = "${FEN_BUILD_SYSTEM:-$ARTIFACT_SYSTEM}",
  targetSystem = "${FEN_TARGET_SYSTEM:-$ARTIFACT_SYSTEM}",
}
EOF

# 3. Stage the module tree: every dist/ tree, plus the runtime pure-Lua deps
#    that the launcher expects to find in the embedded archive.
rm -rf "$ROOT"
mkdir -p "$ROOT"
find packages extensions -type d -name dist -prune -print | sort | while read -r d; do
  cp -R "$d"/. "$ROOT"/
done
cp "$FENNEL_LUA" "$ROOT/fennel.lua"
cp "$DKJSON_LUA" "$ROOT/dkjson.lua"
cp "$LUASOCKET_SRC/socket.lua" "$LUASOCKET_SRC/mime.lua" "$LUASOCKET_SRC/ltn12.lua" "$ROOT/"
mkdir -p "$ROOT/socket"
cp "$LUASOCKET_SRC/http.lua" \
   "$LUASOCKET_SRC/url.lua" \
   "$LUASOCKET_SRC/tp.lua" \
   "$LUASOCKET_SRC/ftp.lua" \
   "$LUASOCKET_SRC/headers.lua" \
   "$LUASOCKET_SRC/smtp.lua" \
   "$ROOT/socket/"

# The Nix artifact embeds LuaRocks so `fen ext build` works without a system
# luarocks. The portable Make build omits it (core agent only) by leaving this
# unset, preserving the existing smaller random-system path.
if [ -n "${LUAROCKS_SRC:-}" ]; then
  mkdir -p "$ROOT/luarocks"
  cp -R "$LUAROCKS_SRC"/. "$ROOT/luarocks"/
fi

# 4. Optional deterministic zip (sorted, fixed mtimes, no extra attrs). The
#    C launcher reads this archive back out of the appended executable.
if [ -n "${FEN_ZIP_OUT:-}" ]; then
  : "${ZIPCMD:?FEN_ZIP_OUT requires ZIPCMD}"
  chmod -R u+rwX,go+rX "$ROOT"
  find "$ROOT" -exec touch -h -d @1 {} + 2>/dev/null \
    || find "$ROOT" -exec touch -h -t 197001010000 {} + 2>/dev/null || true

  ZIP_OUT=$FEN_ZIP_OUT
  ZIP_LIST=${FEN_ZIP_LIST:-$FEN_ZIP_OUT.list}
  mkdir -p "$(dirname "$ZIP_OUT")" "$(dirname "$ZIP_LIST")"
  rm -f "$ZIP_OUT" "$ZIP_LIST"
  ( cd "$ROOT" && find . -type f -print | sort | sed 's#^\./##' ) > "$ZIP_LIST"
  ( cd "$ROOT" && "$ZIPCMD" -q -X -9 "$ZIP_OUT" -@ < "$ZIP_LIST" )
  [ -f "$ZIP_OUT" ] || { echo "package-lua-tree: zip did not create $ZIP_OUT" >&2; exit 1; }
  echo "package-lua-tree: wrote $(cd "$ROOT" && find . -type f | wc -l | tr -d ' ') modules to $ZIP_OUT"
fi
