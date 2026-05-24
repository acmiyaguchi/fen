#!/bin/sh
# portable-pack.sh — build the embedded Lua module archive and append it to a
# freshly linked fen binary. Mirrors the luaTree + fenBinary archive steps in
# nix/artifacts.nix, minus the bundled LuaRocks tree (only `fen ext build`
# native-rock support needs it; the core agent does not).
#
# Driven by `make fen`; expects these in the environment (set from the
# Makefile's portable build section): FENNEL ZIPCMD FENNEL_LUA DKJSON_LUA
# LUASOCKET_SRC FEN_VERSION FEN_GIT_REV FEN_GIT_SHORT FEN_DIRTY ARTIFACT_SYSTEM. Argument 1 is
# the bare binary to append onto (modified in place). NB: the zip program is
# passed as ZIPCMD, not ZIP — Info-ZIP treats a $ZIP environment variable as
# default CLI options.
set -eu

BIN=${1:?usage: portable-pack.sh <binary>}
: "${FENNEL:?}" "${ZIPCMD:?}" "${FENNEL_LUA:?}" "${DKJSON_LUA:?}" "${LUASOCKET_SRC:?}"
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
  source = "make",
  lastModified = "",
  buildSystem = "${ARTIFACT_SYSTEM}",
  targetSystem = "${ARTIFACT_SYSTEM}",
}
EOF

# 3. Stage the module tree: every dist/ tree, plus fennel.lua and dkjson.lua,
#    flattened under one share root just as the embedded zip expects them.
ROOT=build/archive-root
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

# 4. Deterministic zip (sorted, fixed mtimes, no extra attrs), then append.
#    fen.c reads the archive back out of /proc/self/exe at startup.
chmod -R u+rwX,go+rX "$ROOT"
find "$ROOT" -exec touch -h -d @1 {} + 2>/dev/null \
  || find "$ROOT" -exec touch -h -t 197001010000 {} + 2>/dev/null || true

# Use absolute paths and a pre-written file list (not a pipe into zip): the
# list is built in a subshell that cd's into $ROOT, then zip consumes it from
# the same cwd so stored names stay archive-root-relative.
ZIP_OUT="$(pwd)/build/fen-lua.zip"
ZIP_LIST="$(pwd)/build/fen-lua.list"
rm -f "$ZIP_OUT" "$ZIP_LIST"
( cd "$ROOT" && find . -type f -print | sort | sed 's#^\./##' ) > "$ZIP_LIST"
( cd "$ROOT" && "$ZIPCMD" -q -X -9 "$ZIP_OUT" -@ < "$ZIP_LIST" )
[ -f "$ZIP_OUT" ] || { echo "portable-pack: zip did not create $ZIP_OUT" >&2; exit 1; }
cat "$ZIP_OUT" >> "$BIN"
chmod +x "$BIN"

echo "portable-pack: embedded $(cd "$ROOT" && find . -type f | wc -l | tr -d ' ') modules into $BIN"
