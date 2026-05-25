#!/bin/sh
# Auto-record the "what is fen?" hero demo (issue #141).
#
# Drives a real fen session non-interactively (via scripts/docs/record-hero-cast.fnl
# and the host-side PTY helper), then renders the README GIF and the docs-site
# SVG fallback. `make hero-cast` is the entry point.
#
# This calls a real model, so it needs a provider key in the env and the answer
# varies run to run — re-run until you get a good take, and SCRUB the cast before
# committing.
#
# Env: FEN_BIN (fen binary; else `fen` on PATH), FEN_HERO_PROVIDER (default
# openai), FEN_HERO_MODEL, FEN_HERO_PROMPT. Run inside `nix develop`.
set -eu

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/../.." && pwd))
cd "$ROOT"

FEN_BIN=${FEN_BIN:-$(command -v fen || true)}
if [ -z "$FEN_BIN" ] || [ ! -x "$FEN_BIN" ]; then
  echo "record-hero-cast: no fen binary (set FEN_BIN=... or build with 'nix build .#fen')" >&2
  exit 127
fi
export FEN_BIN
for cmd in fennel termtosvg agg gifsicle; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "record-hero-cast: missing $cmd (use 'nix develop')" >&2
    exit 127
  }
done

# Build the test-only PTY helper if absent (same recipe as run-tests.sh).
PTY_SO=packages/testing/dist/fen_pty.so
if [ ! -f "$PTY_SO" ]; then
  echo "record-hero-cast: building $PTY_SO ..." >&2
  CC=${CC:-cc}
  CFLAGS=${CFLAGS:-"-O2 -fPIC -Wall"}
  LUA_INCDIR=${LUA_INCDIR:-/usr/include/lua5.4}
  mkdir -p "$(dirname "$PTY_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS -I"$LUA_INCDIR" -shared packages/testing/vendor/fen_pty.c -lutil -o "$PTY_SO"
fi

CAST=docs/assets/casts/what-is-fen.cast
echo "record-hero-cast: recording a live fen turn (provider=${FEN_HERO_PROVIDER:-openai})..." >&2
fennel scripts/docs/record-hero-cast.fnl

[ -f "$CAST" ] || { echo "record-hero-cast: no cast produced" >&2; exit 1; }

echo "record-hero-cast: SCRUB CHECK — review the cast for absolute paths, usernames," >&2
echo "  or echoed secrets before committing:  \$EDITOR $CAST" >&2

# README GIF: agg anti-aliases glyphs into hundreds of colors, but a terminal
# demo is only ~8 ANSI colors, so quantize hard with gifsicle. A lower fps and
# 2x speed keep the looping teaser small; the docs-site player uses the
# full-rate cast for careful viewing.
gif_tmp=$(mktemp -t hero-gif.XXXXXX.gif)
agg --idle-time-limit 1 --fps-cap 10 --speed 2 "$CAST" "$gif_tmp"
gifsicle -O3 --colors 8 "$gif_tmp" -o docs/assets/demo.gif
rm -f "$gif_tmp"
# base16_default_dark is a standard white-on-dark palette; termtosvg's default
# template renders the terminal's default foreground green, which is neither
# readable nor true to fen's TUI.
termtosvg render -M 1500 -t base16_default_dark "$CAST" docs/assets/demo.svg
echo "record-hero-cast: wrote $CAST, docs/assets/demo.gif, docs/assets/demo.svg" >&2
echo "record-hero-cast: preview with 'make docs && make docs-serve'; re-run for a better take." >&2
