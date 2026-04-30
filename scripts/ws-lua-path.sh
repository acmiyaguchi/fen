#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=''
for d in "$ROOT"/packages/*/dist "$ROOT"/packages/*/*/dist; do
  [ -d "$d" ] || continue
  out="$d/?.lua;$d/?/init.lua;$out"
done
printf '%s' "$out"
