#!/bin/sh
# Trace replay: Quint traces of the model are fed through the real TUI ingest.
# MAIN selects which model instance must match today's code (`current` until
# the streaming-row fix lands, then `fixed`).
#
# --negative replays the other instance, which differs from today's code, so
# the replay must fail: proof that a divergence is reported, not swallowed.
set -eu
QUINT=${QUINT:-quint}
MAIN=${SPEC_NETWORK_MAIN:-current}
if [ "${1-}" = "--negative" ]; then
  if [ "$MAIN" = current ]; then MAIN=fixed; else MAIN=current; fi
fi
TRACES=${SPEC_REPLAY_TRACES:-200}
out=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-network.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$QUINT" run --main="$MAIN" --max-samples="$TRACES" --n-traces="$TRACES" \
  --max-steps=14 --seed="${SPEC_SEED:-0x5eed}" \
  --out-itf="$out/trace_{seq}.itf.json" spec/network/model.qnt >/dev/null 2>&1
ls "$out"/trace_*.itf.json > "$out/index.txt"
# Keep the runner's exit status: a pipeline would report tail's instead.
status=0
FEN_SPEC_ITF_MAIN=$MAIN FEN_SPEC_ITF_INDEX=$out/index.txt \
  sh scripts/test/run-tests.sh spec/network/replay_test.fnl > "$out/replay.log" 2>&1 || status=$?
tail -1 "$out/replay.log"
exit "$status"
