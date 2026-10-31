#!/bin/sh
# Conformance: the model's decide/advance tables == fen.util.wire_session.
set -eu
QUINT=${QUINT:-quint}
out=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-wire.XXXXXX")
trap 'rm -rf "$out"' EXIT
(cd spec/wire && "$QUINT" run --main=conform --max-steps=0 --max-samples=1 \
  --out-itf="$out/table.itf.json" conform.qnt >/dev/null 2>&1)
fennel --add-fennel-path 'packages/util/src/?.fnl;packages/util/src/?/init.fnl' \
  scripts/spec/conform-wire.fnl "$out/table.itf.json"
