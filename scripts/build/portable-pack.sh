#!/bin/sh
# portable-pack.sh — build the embedded Lua module archive and append it to a
# freshly linked fen binary.
#
# Driven by `make fen`; expects these in the environment (set from the
# Makefile's portable build section): FENNEL ZIPCMD FENNEL_LUA DKJSON_LUA
# LUASOCKET_SRC FEN_VERSION FEN_GIT_REV FEN_GIT_SHORT FEN_DIRTY ARTIFACT_SYSTEM.
# Argument 1 is the bare binary to append onto (modified in place). NB: the zip
# program is passed as ZIPCMD, not ZIP — Info-ZIP treats a $ZIP environment
# variable as default CLI options.
set -eu

BIN=${1:?usage: portable-pack.sh <binary>}
: "${FENNEL:?}" "${ZIPCMD:?}" "${FENNEL_LUA:?}" "${DKJSON_LUA:?}" "${LUASOCKET_SRC:?}"
: "${FEN_VERSION:?}" "${ARTIFACT_SYSTEM:?}"

# Build/stage/zip via the same module-tree script used by the Nix artifact. The
# portable build intentionally leaves LUAROCKS_SRC unset: `fen ext build`
# native-rock support is a Nix release feature, while the random-system build
# keeps only the core agent runtime.
ROOT=build/archive-root
ZIP_OUT="$(pwd)/build/fen-lua.zip"
ZIP_LIST="$(pwd)/build/fen-lua.list"
FEN_BUILD_SOURCE=make \
FEN_BUILD_SYSTEM="$ARTIFACT_SYSTEM" \
FEN_TARGET_SYSTEM="$ARTIFACT_SYSTEM" \
FEN_ZIP_OUT="$ZIP_OUT" \
FEN_ZIP_LIST="$ZIP_LIST" \
  sh scripts/build/package-lua-tree.sh "$ROOT"

cat "$ZIP_OUT" >> "$BIN"
chmod +x "$BIN"

echo "portable-pack: embedded $(cd "$ROOT" && find . -type f | wc -l | tr -d ' ') modules into $BIN"
