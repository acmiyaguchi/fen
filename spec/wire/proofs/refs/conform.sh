#!/bin/sh
# Conformance of the ref-accounting model (refs, from initReady) with the real
# rpc child: Quint traces (with --mbt action labels) are replayed through
# fen.extensions.rpc, fen.core.tasks, and fen.turn_submit with a scripted
# turn body, comparing every line control's terminal notices on the wire,
# its ack status, and whether the child exited, after every step
# (spec/wire/proofs/refs/conform_test.fnl).
# --negative replays with the agent never draining its queues and succeeds
# only if the harness reports a mismatch, so a harness that cannot see a
# missing notice fails check-spec.
set -eu
QUINT=${QUINT:-quint}
TRACES=${SPEC_REPLAY_TRACES:-300}
corrupt=
[ "${1-}" = "--negative" ] && corrupt=1
out=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-refs.XXXXXX")
trap 'rm -rf "$out"' EXIT

(cd spec/wire/proofs/refs && "$QUINT" run --main=refs --init=initReady --mbt \
  --max-samples="$TRACES" --n-traces="$TRACES" --max-steps=14 \
  --seed="${SPEC_SEED:-0x5eed}" --out-itf="$out/trace_{seq}.itf.json" \
  model.qnt >/dev/null 2>&1)
ls "$out"/trace_*.itf.json > "$out/index.txt"
status=0
FEN_SPEC_CONFORM_CORRUPT=$corrupt FEN_SPEC_ITF_INDEX=$out/index.txt \
  sh scripts/test/run-tests.sh spec/wire/proofs/refs/conform_test.fnl > "$out/replay.log" 2>&1 || status=$?
grep -A5 '^refs conformance:' "$out/replay.log" || tail -15 "$out/replay.log"
if [ -n "$corrupt" ]; then
  [ "$status" -ne 0 ] && exit 1
  echo "negative: an agent that never drains was not detected"
  exit 0
fi
exit "$status"
