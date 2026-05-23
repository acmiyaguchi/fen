#!/usr/bin/env bash
# Smoke test against the live providers configured on this machine.
#
# Runs a tiny `--print` round-trip against each provider whose credentials
# are present (env var or auth.json). The prompt requires a harmless read tool
# call so both text and tool wire-format regressions surface before they bite
# during interactive use. Skips providers without credentials. Each run is
# gated on `OK` appearing in the output.
#
# Usage: FEN_BIN=/path/to/fen scripts/smoke/live.sh
# Defaults to `fen` on PATH; does not build with Nix.
# Skip a provider:           SKIP_OPENAI=1 scripts/smoke/live.sh
# Add per-provider --model:  OPENAI_MODEL=gpt-4o-mini scripts/smoke/live.sh

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PROMPT="Use the read tool to read README.md, then reply with the single word OK"
PASS=0
FAIL=0

run_one() {
  local label=$1; shift
  local provider=$1; shift
  printf '== %-32s ' "$label"
  local out
  local fen_bin
  fen_bin=${FEN_BIN:-fen}
  if ! out=$(timeout 60 env FEN_BIN="$fen_bin" ./scripts/dev/fen-dev \
               --provider "$provider" --no-session \
               --print "$PROMPT" "$@" 2>&1); then
    printf 'FAIL\n'
    printf '%s\n' "$out" | head -6 | sed 's/^/    /'
    FAIL=$((FAIL+1))
    return
  fi
  if printf '%s' "$out" | grep -qi 'OK'; then
    PASS=$((PASS+1))
    printf 'PASS\n'
  else
    printf 'WEIRD (no OK in reply)\n'
    printf '%s\n' "$out" | head -3 | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
}

if [[ -z "${SKIP_OPENAI:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
  run_one "openai (chat completions)" openai \
    ${OPENAI_MODEL:+--model "$OPENAI_MODEL"}
fi

if [[ -z "${SKIP_OPENAI_RESPONSES:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
  run_one "openai-responses" openai-responses \
    ${OPENAI_RESPONSES_MODEL:+--model "$OPENAI_RESPONSES_MODEL"}
fi

if [[ -z "${SKIP_ANTHROPIC:-}" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
  run_one "anthropic" anthropic \
    ${ANTHROPIC_MODEL:+--model "$ANTHROPIC_MODEL"}
fi

CODEX_AUTH="${FEN_AUTH_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/fen}/auth.json"
if [[ -z "${SKIP_OPENAI_CODEX:-}" \
      && -f "$CODEX_AUTH" \
      && $(grep -c '"openai-codex"' "$CODEX_AUTH" 2>/dev/null) -gt 0 ]]; then
  run_one "openai-codex (subscription)" openai-codex \
    ${OPENAI_CODEX_MODEL:+--model "$OPENAI_CODEX_MODEL"}
fi

if [[ $((PASS + FAIL)) -eq 0 ]]; then
  echo "no providers had credentials; nothing to smoke"
  exit 2
fi

echo
printf 'smoke: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
