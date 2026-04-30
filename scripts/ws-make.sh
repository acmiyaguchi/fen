#!/bin/sh
set -eu
cmd=${1:-build}
filter=${2:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
packages='packages/util
packages/core
packages/providers/openai
packages/providers/openai-codex
packages/providers/anthropic
packages/extensions/builtin-tools
packages/extensions/builtin-commands
packages/extensions/default-prompt
packages/extensions/tui
packages/extensions/mem
packages/extensions/skills
packages/extensions/agent-state
packages/extensions/handoff
packages/fen'
match_pkg() {
  d=$1
  [ -z "$filter" ] && return 0
  case "$d" in *"$filter"*) return 0;; esac
  rn=$(find "$ROOT/$d" -maxdepth 1 -name '*-1.rockspec' -exec basename {} \; 2>/dev/null | sed 's/-1\.rockspec$//' | head -1)
  [ "$rn" = "$filter" ] && return 0
  return 1
}
found=0
printf '%s
' "$packages" | while IFS= read -r d; do
  [ -n "$d" ] || continue
  if match_pkg "$d"; then
    found=1
    echo "==> $cmd $d"
    make -C "$ROOT/$d" "$cmd"
  fi
done
