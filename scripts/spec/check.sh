#!/bin/sh
# Run the Quint design models under spec/.
#
# Each spec/<domain>/ holds model.qnt and checks.tsv. A checks.tsv row is
#   <main module> <TAB> <invariant> <TAB> holds|violated
# `holds`    — simulation must find no counterexample.
# `violated` — simulation must find one: the row records a known design bug in
#              the current code. When the bug is fixed, update the model and
#              flip the row to `holds`.
#
# A domain may also ship conform.sh, which checks the model against the real
# code (table comparison or trace replay); it runs after the domain's checks.
#
# Usage: sh scripts/spec/check.sh [spec/<domain> ...]
# Env: QUINT (default quint), SPEC_SAMPLES, SPEC_STEPS, SPEC_SEED.
set -u
QUINT=${QUINT:-quint}
SAMPLES=${SPEC_SAMPLES:-20000}
STEPS=${SPEC_STEPS:-20}
SEED=${SPEC_SEED:-0x5eed}

if ! command -v "$QUINT" >/dev/null 2>&1; then
  echo "error: quint not found (use nix develop, or QUINT=...)" >&2
  exit 127
fi

if [ $# -eq 0 ]; then
  set -- spec/*/
fi

fail=0
total=0
tab=$(printf '\t')
for dir in "$@"; do
  dir=${dir%/}
  model="$dir/model.qnt"
  checks="$dir/checks.tsv"
  [ -f "$model" ] && [ -f "$checks" ] || continue
  if ! "$QUINT" typecheck "$model" >/dev/null 2>&1; then
    echo "FAIL $dir: typecheck"
    "$QUINT" typecheck "$model" 2>&1 | grep -v '^\[DEBUG\]' | sed 's/^/    /'
    fail=$((fail + 1))
    continue
  fi
  while IFS="$tab" read -r main inv expect; do
    case "$main" in ''|'#'*) continue ;; esac
    total=$((total + 1))
    out=$("$QUINT" run --main="$main" --invariant="$inv" \
      --max-samples="$SAMPLES" --max-steps="$STEPS" --seed="$SEED" \
      "$model" 2>&1)
    status=$?
    if [ $status -eq 0 ]; then got=holds
    elif printf '%s' "$out" | grep -q '^\[violation\]'; then got=violated
    else got=error
    fi
    if [ "$got" = "$expect" ]; then
      echo "ok   $dir $main.$inv ($got)"
    else
      echo "FAIL $dir $main.$inv: expected $expect, got $got"
      [ "$got" = error ] && printf '%s\n' "$out" | grep -v '^\[DEBUG\]' | tail -15 | sed 's/^/    /'
      fail=$((fail + 1))
    fi
  done < "$checks"
  if [ -f "$dir/conform.sh" ]; then
    total=$((total + 1))
    if out=$(QUINT="$QUINT" sh "$dir/conform.sh" 2>&1); then
      echo "ok   $dir conformance: $(printf '%s' "$out" | tail -1)"
    else
      echo "FAIL $dir conformance"
      printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
      fail=$((fail + 1))
    fi
  fi
done

echo "spec: $total checks, $fail failed"
[ $fail -eq 0 ]
