#!/bin/sh
# Conformance of the wire model with the real code, in two parts:
#   table      the model's decide/advance tables == fen.util.wire_session,
#              pair by pair, and the model covers every state, control, and
#              event the code's tables define (scripts/spec/conform-wire.fnl);
#   lifecycle  Quint traces of the model replayed through the real rpc child:
#              the child's lifecycle events must equal the model's, step by
#              step (spec/wire/lifecycle_test.fnl).
# --negative runs both against a deliberately wrong model (one corrupted table
# row; traces of the `fixed` instance, which today's code does not follow)
# and succeeds only if neither harness reports a mismatch, so a harness that
# cannot detect one makes check-spec fail.
set -eu
QUINT=${QUINT:-quint}
MAIN=${SPEC_WIRE_MAIN:-current}
TRACES=${SPEC_REPLAY_TRACES:-300}
negative=
[ "${1-}" = "--negative" ] && negative=1
out=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-wire.XXXXXX")
trap 'rm -rf "$out"' EXIT

table() {
  (cd spec/wire && "$QUINT" run --main=conform --max-steps=0 --max-samples=1 \
    --out-itf="$out/table.itf.json" conform.qnt >/dev/null 2>&1)
  FEN_SPEC_CONFORM_CORRUPT=$1 \
    fennel --add-fennel-path 'packages/util/src/?.fnl;packages/util/src/?/init.fnl' \
    scripts/spec/conform-wire.fnl "$out/table.itf.json"
}

lifecycle() {
  rm -f "$out"/trace_*.itf.json
  "$QUINT" run --main="$1" --max-samples="$TRACES" --n-traces="$TRACES" \
    --max-steps=16 --seed="${SPEC_SEED:-0x5eed}" \
    --out-itf="$out/trace_{seq}.itf.json" spec/wire/model.qnt >/dev/null 2>&1
  ls "$out"/trace_*.itf.json > "$out/index.txt"
  # Keep the runner's exit status: a pipeline would report tail's instead.
  status=0
  FEN_SPEC_ITF_MAIN=$1 FEN_SPEC_ITF_INDEX=$out/index.txt \
    sh scripts/test/run-tests.sh spec/wire/lifecycle_test.fnl > "$out/replay.log" 2>&1 || status=$?
  grep '^wire lifecycle:' "$out/replay.log" || tail -5 "$out/replay.log"
  return "$status"
}

if [ -n "$negative" ]; then
  if table 1; then echo "table: corrupted model not detected"; exit 0; fi
  if [ "$MAIN" = current ]; then other=unfixed; else other=current; fi
  if lifecycle "$other"; then echo "lifecycle: $other traces not detected"; exit 0; fi
  exit 1
fi
table ""
lifecycle "$MAIN"
