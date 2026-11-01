#!/bin/sh
# Conformance of the turn-mailbox model (requestsSpec) with fen.core.tasks:
# Quint traces (with --mbt action labels) are replayed through the real pure
# step, comparing turn, queue lengths, idle-start, and line accounting after
# every step (spec/core/tasks/conform_test.fnl).
# --negative replays with every turn end dropped and succeeds only if the
# harness reports a mismatch, so a harness that cannot see one fails check-spec.
set -eu
QUINT=${QUINT:-quint}
TRACES=${SPEC_REPLAY_TRACES:-300}
corrupt=
[ "${1-}" = "--negative" ] && corrupt=1
out=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-tasks.XXXXXX")
trap 'rm -rf "$out"' EXIT

(cd spec/core/tasks && "$QUINT" run --main=requestsSpec --mbt \
  --max-samples="$TRACES" --n-traces="$TRACES" --max-steps=16 \
  --seed="${SPEC_SEED:-0x5eed}" --out-itf="$out/trace_{seq}.itf.json" \
  model.qnt >/dev/null 2>&1)
ls "$out"/trace_*.itf.json > "$out/index.txt"
status=0
FEN_SPEC_CONFORM_CORRUPT=$corrupt FEN_SPEC_ITF_INDEX=$out/index.txt \
  sh scripts/test/run-tests.sh spec/core/tasks/conform_test.fnl > "$out/replay.log" 2>&1 || status=$?
grep '^tasks conformance:' "$out/replay.log" || tail -5 "$out/replay.log"
if [ -n "$corrupt" ]; then
  [ "$status" -ne 0 ] && exit 1
  echo "negative: dropped turn ends not detected"
  exit 0
fi
exit "$status"
