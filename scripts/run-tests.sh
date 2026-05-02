#!/bin/sh
set -eu

# Tests exercise native helpers directly (fen_http.so) and indirectly via
# cooperative bash/process I/O (fen_process.so). Keep this script self-contained
# so `make test` works from a source checkout after `make clean` / without a
# prior Nix build step.
if [ ! -f packages/util/dist/fen_http.so ] || \
   [ ! -f packages/util/dist/fen_process.so ] || \
   [ ! -f packages/extensions/tui/dist/termbox2.so ]; then
  sh scripts/build-native-modules.sh
fi

exec busted --loaders=lua,fennel --helper=tests/busted-helper.lua --pattern=_test packages tests
