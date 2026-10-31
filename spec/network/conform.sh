#!/bin/sh
# Trace replay: Quint traces of the model are fed through the real TUI ingest.
# MAIN selects which model instance must match today's code (`current` until
# the streaming-row fix lands, then `fixed`).
set -eu
QUINT=${QUINT:-quint}
MAIN=${SPEC_NETWORK_MAIN:-current}
TRACES=${SPEC_REPLAY_TRACES:-200}
out=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-network.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$QUINT" run --main="$MAIN" --max-samples="$TRACES" --n-traces="$TRACES" \
  --max-steps=14 --seed="${SPEC_SEED:-0x5eed}" \
  --out-itf="$out/trace_{seq}.itf.json" spec/network/model.qnt >/dev/null 2>&1
ls "$out"/trace_*.itf.json > "$out/index.txt"
FEN_SPEC_ITF_MAIN=$MAIN FEN_SPEC_ITF_INDEX=$out/index.txt \
  sh scripts/test/run-tests.sh spec/network/replay_test.fnl 2>&1 | tail -1
