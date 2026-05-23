#!/usr/bin/env sh
# Deterministic local provider smoke test.
#
# Starts a tiny Fennel/LuaSocket OpenAI-compatible mock service and drives
# Fen's print presenter through real provider conversion, HTTP transport, read
# tool execution, provider retry, and final assistant output. Use
# FEN_BIN=/path/to/fen to select the binary used by scripts/dev/fen-dev.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$(dirname "$SCRIPT_DIR")")
FENNEL=${FENNEL:-fennel}
PROMPT='Use the read tool to read README.md, then reply with the single word OK'
TMPDIR=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$TMPDIR/fen-mock-smoke.XXXXXX")
SERVER_PID=

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

PORT_FILE=$TMP/port
"$FENNEL" "$SCRIPT_DIR/mock-openai.fnl" "$PORT_FILE" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

tries=0
while [ ! -s "$PORT_FILE" ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 100 ]; then
    echo "mock server did not start" >&2
    cat "$TMP/server.log" >&2 || true
    exit 1
  fi
  sleep 0.05
done
PORT=$(cat "$PORT_FILE")
BASE_URL="http://127.0.0.1:$PORT/v1"

mkdir -p "$TMP/config/fen" "$TMP/state" "$TMP/home"
cat > "$TMP/config/fen/models.json" <<EOF
{"providers":{"mock-openai":{"api":"openai-completions","baseUrl":"$BASE_URL","apiKey":"dummy","models":[{"id":"mock-chat"},{"id":"mock-chat-retry"}]},"mock-openai-responses":{"api":"openai-responses","baseUrl":"$BASE_URL","apiKey":"dummy","models":[{"id":"mock-responses"},{"id":"mock-responses-retry"}]}}}
EOF

run_case() {
  provider=$1
  model=$2
  label="$provider ($model)"
  out=$TMP/$provider.out
  if XDG_CONFIG_HOME="$TMP/config" \
     XDG_STATE_HOME="$TMP/state" \
     HOME="$TMP/home" \
     "$ROOT/scripts/dev/fen-dev" --provider "$provider" --model "$model" \
       --no-session --print "$PROMPT" >"$out" 2>&1 && grep -q OK "$out"; then
    printf '== %-32s PASS\n' "$label"
  else
    printf '== %-32s FAIL\n' "$label"
    sed -n '1,80p' "$out" | sed 's/^/    /'
    echo "mock server log:" >&2
    cat "$TMP/server.log" >&2 || true
    exit 1
  fi
}

run_case mock-openai mock-chat
run_case mock-openai-responses mock-responses
run_case mock-openai mock-chat-retry
run_case mock-openai-responses mock-responses-retry

if ! grep -q 'mock transient 500 for /v1/chat/completions:mock-chat-retry' "$TMP/server.log" || \
   ! grep -q 'mock transient 500 for /v1/responses:mock-responses-retry' "$TMP/server.log"; then
  echo "retry scenario did not hit expected transient failures" >&2
  cat "$TMP/server.log" >&2 || true
  exit 1
fi

echo "mock smoke: 4 pass, 0 fail"
