#!/bin/sh
# Resource-constrained TUI-stall harness for issue #167.
#
# Drives the real cooperative streaming transport (fen_http.so), the real SSE
# parser, and a per-event JSON decode against a localhost SSE stream, timing the
# wall gap between cooperative yields — the same metric the TUI's stall warning
# uses. FEN_DEBUG_CHUNK_DELAY_MS injects slow per-chunk cost so a fast desktop
# reproduces the BB10/ARM stall profile; the harness prints a gap histogram and
# fails if any single resume exceeds FEN_STALL_BUDGET_MS.
#
# Usage:
#   scripts/dev/stall-check.sh                 # defaults: delay 15ms, budget 250ms
#   FEN_DEBUG_CHUNK_DELAY_MS=40 scripts/dev/stall-check.sh
#   FEN_STALL_NICE=1 scripts/dev/stall-check.sh   # also run under nice/taskset
#
# Env knobs (all optional):
#   FEN_DEBUG_CHUNK_DELAY_MS  ms slept per drained chunk slice   (default 15)
#   FEN_STALL_BUDGET_MS       max allowed per-resume gap         (default 250)
#   FEN_STALL_BODY_KB         synthetic SSE body size            (default 1536)
#   FEN_STALL_NICE            non-empty: wrap with nice/taskset for extra squeeze
set -eu

cd "$(dirname "$0")/../.."

: "${FEN_DEBUG_CHUNK_DELAY_MS:=15}"
: "${FEN_STALL_BUDGET_MS:=250}"
: "${FEN_STALL_BODY_KB:=1536}"
export FEN_DEBUG_CHUNK_DELAY_MS FEN_STALL_BUDGET_MS FEN_STALL_BODY_KB

TEST=packages/util/tests/smoke/stall_check_test.fnl

# Optional external OS constraint to compound the in-source delay. `nice` is
# POSIX; pin to one CPU with taskset when available (Linux) to make scheduling
# jitter — and thus stalls — more pronounced.
PREFIX=""
if [ -n "${FEN_STALL_NICE:-}" ]; then
  PREFIX="nice -n 19"
  if command -v taskset >/dev/null 2>&1; then
    PREFIX="taskset -c 0 $PREFIX"
  fi
fi

echo "stall-check: delay=${FEN_DEBUG_CHUNK_DELAY_MS}ms budget=${FEN_STALL_BUDGET_MS}ms body=${FEN_STALL_BODY_KB}KB ${PREFIX:+constraint=\"$PREFIX\"}"
# shellcheck disable=SC2086
exec $PREFIX sh scripts/test/run-tests.sh "$TEST"
