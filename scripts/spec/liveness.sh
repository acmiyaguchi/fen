#!/bin/sh
# TLC liveness check for the session lease (spec/core/tasks/proofs/liveness).
# Not part of `make check` or check-spec: run with `make check-liveness`.
#
# temporal.tsv:   <property> <TAB> holds|violated <TAB> why
# temporal-mutants.tsv:
#              <sed edit> <TAB> <property> <TAB> description; the edited
#              model must violate the property (the check is not vacuous).
#
# Needs quint and TLC + a JDK. If `tlc` is not on PATH, runs quint inside
# `nix shell nixpkgs#tlaplus nixpkgs#jdk`. Env: QUINT (default quint).
set -u
DIR=${1:-spec/core/tasks/proofs/liveness}
QUINT=${QUINT:-quint}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if command -v tlc >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  run() { yes | "$QUINT" verify --backend tlc --main liveness --temporal "$2" "$1"; }
else
  run() { yes | nix shell nixpkgs#tlaplus nixpkgs#jdk --command "$QUINT" verify --backend tlc --main liveness --temporal "$2" "$1"; }
fi

fail=0
check() { # model property expect label
  if run "$1" "$2" >"$TMP/out" 2>&1; then got=holds
  elif grep -q '\[violation\]' "$TMP/out"; then got=violated
  else got=error; fi
  if [ "$got" = "$3" ]; then echo "ok    $4: $2 $got"
  else echo "FAIL  $4: $2 expected $3, got $got"; tail -20 "$TMP/out"; fail=1; fi
}

grep -v '^#' "$DIR/temporal.tsv" | while IFS="$(printf '\t')" read -r prop expect _; do
  [ -n "$prop" ] && check "$DIR/model.qnt" "$prop" "$expect" model
done >"$TMP/props.log"
cat "$TMP/props.log"

i=0
grep -v '^#' "$DIR/temporal-mutants.tsv" | while IFS="$(printf '\t')" read -r edit prop desc; do
  [ -n "$edit" ] || continue
  i=$((i + 1))
  m="$TMP/m$i/model.qnt"; mkdir -p "$TMP/m$i"
  sed "$edit" "$DIR/model.qnt" >"$m"
  if cmp -s "$m" "$DIR/model.qnt"; then echo "FAIL  mutant $i: sed edit did not apply ($desc)"; continue; fi
  check "$m" "$prop" violated "mutant $i ($desc)"
done >"$TMP/mut.log"
cat "$TMP/mut.log"

grep -q '^FAIL' "$TMP/props.log" "$TMP/mut.log" && fail=1
exit $fail
