#!/bin/sh
# Trace replay against the real code, at two boundaries:
#   replay_test.fnl    the model's events through the real TUI ingest;
#   producer_test.fnl  the model's actions as a scripted HTTP transport under
#                      the real turn_submit/agent/provider/retry chain: the
#                      events it emits must equal the model's, and the TUI
#                      state must match after every model step.
# MAIN selects which model instance must match today's code (`current` and
# `fixed` now carry the streaming-row fixes #629 and #630).
#
# --negative replays `unfixed`, which lacks the fixes and differs from today's
# code, so the replay must fail: proof that a divergence is reported, not swallowed.
set -eu
QUINT=${QUINT:-quint}
MAIN=${SPEC_NETWORK_MAIN:-current}
if [ "${1-}" = "--negative" ]; then
  if [ "$MAIN" = unfixed ]; then MAIN=current; else MAIN=unfixed; fi
fi
TRACES=${SPEC_REPLAY_TRACES:-200}
# Extra traces from `stepNoCancel`, which reach completed turns far more often.
TRACES_NC=${SPEC_REPLAY_TRACES_NOCANCEL:-100}
out=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-network.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$QUINT" run --main="$MAIN" --max-samples="$TRACES" --n-traces="$TRACES" \
  --max-steps=14 --seed="${SPEC_SEED:-0x5eed}" \
  --out-itf="$out/trace_{seq}.itf.json" spec/network/model.qnt >/dev/null 2>&1
"$QUINT" run --main="$MAIN" --step=stepNoCancel --max-samples="$TRACES_NC" \
  --n-traces="$TRACES_NC" --max-steps=14 --seed="${SPEC_SEED:-0x5eed}" \
  --out-itf="$out/nocancel_{seq}.itf.json" spec/network/model.qnt >/dev/null 2>&1
ls "$out"/trace_*.itf.json "$out"/nocancel_*.itf.json > "$out/index.txt"
# Keep the runner's exit status: a pipeline would report tail's instead.
status=0
FEN_SPEC_ITF_MAIN=$MAIN FEN_SPEC_ITF_INDEX=$out/index.txt \
  sh scripts/test/run-tests.sh spec/network/replay_test.fnl \
  spec/network/producer_test.fnl > "$out/replay.log" 2>&1 || status=$?
tail -1 "$out/replay.log"
exit "$status"
