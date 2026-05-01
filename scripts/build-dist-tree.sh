#!/bin/sh
set -eu

FENNEL=${FENNEL:-fennel}
VERSION=${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo unknown)}

FENNEL="$FENNEL" "$FENNEL" scripts/fennel-build.fnl
mkdir -p packages/fen/dist/fen
printf 'return "%s"\n' "$VERSION" > packages/fen/dist/fen/version.lua
sh scripts/build-native-modules.sh
