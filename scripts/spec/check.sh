#!/bin/sh
# Run the Quint design models under spec/.
#
# Each spec/<domain>/ and spec/core/<primitive>/ holds model.qnt and checks.tsv.
# A checks.tsv row is
#   <main module> <TAB> <invariant> <TAB> holds|violated [<TAB> issues]
# `holds`    — simulation must find no counterexample.
# `violated` — simulation must find one: the row records a known design bug in
#              the current code, and `issues` names the GitHub issue(s) for it
#              (milestone `modeling`). When the bug is fixed, update the model
#              and flip the row to `holds`.
#
# A spec dir may also ship:
#   conform.sh     checks the model against the real code (table comparison or
#                  trace replay). `conform.sh --negative` runs it against a
#                  deliberately wrong model and must fail, so a broken harness
#                  cannot report success.
#   witnesses.qnt  module `witnesses`: deterministic `run` traces (quint test,
#                  names ending in Test). Every issue a violated row names
#                  needs a witness `w<issue>...Test` showing that issue's
#                  counterexample, and a dir with fixed/proposed instances
#                  needs `reach...Test` runs showing their interesting cases
#                  are reachable (no vacuous pass).
#   mutants.tsv    <file> <TAB> <sed expression> <TAB> <main> <TAB> <invariant>
#                  <TAB> <description>: the model with that edit applied must
#                  violate the invariant (the check is not vacuous).
#
# Rows run in parallel (SPEC_JOBS, default: online CPUs). The `holds` rows of
# one main module share a single `quint run --invariants ...` (and are re-run
# one by one only if that fails); each `violated` row needs its own run, since
# simulation stops at the first counterexample. A `holds` run is split into
# SPEC_SHARDS runs (default 2) of SAMPLES/SHARDS samples with seeds SEED,
# SEED+1, ...: the same sample budget, finished in about half the time.
# Output is in checks.tsv order.
#
# Usage: sh scripts/spec/check.sh [spec/<domain> | spec/core/<primitive> ...]
# Env: QUINT (default quint), SPEC_SAMPLES, SPEC_STEPS, SPEC_SEED, SPEC_JOBS,
#      SPEC_SHARDS.
set -u
QUINT=${QUINT:-quint}
SAMPLES=${SPEC_SAMPLES:-20000}
STEPS=${SPEC_STEPS:-20}
SEED=${SPEC_SEED:-0x5eed}
JOBS=${SPEC_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
SHARDS=${SPEC_SHARDS:-2}
tab=$(printf '\t')

# ---- worker: one job, result written to $out ---------------------------
# Fields: out kind dir main inv expect issues ("-" marks an empty field).
if [ "${1-}" = "--job" ]; then
  IFS=$tab
  set -f
  # shellcheck disable=SC2086
  set -- $2
  out=$1 kind=$2 dir=$3 main=$4 inv=$5 expect=$6 issues=$7
  [ "$issues" = - ] && issues=
  # One row: run it, compare with the expectation, print one result line.
  # Optional $2/$3: seed and sample count (a holds shard being re-run).
  row() {
    log=$("$QUINT" run --main="$main" --invariant="$1" \
      --max-samples="${3:-$SAMPLES}" --max-steps="$STEPS" --seed="${2:-$SEED}" \
      "$dir/model.qnt" 2>&1)
    status=$?
    if [ $status -eq 0 ]; then got=holds
    elif printf '%s' "$log" | grep -q '^\[violation\]'; then got=violated
    else got=error
    fi
    if [ "$got" = "$expect" ]; then
      echo "ok   $dir $main.$1 ($got${issues:+ $issues})"
    else
      echo "FAIL $dir $main.$1: expected $expect, got $got${issues:+ ($issues)}"
      [ "$got" = error ] && printf '%s\n' "$log" | grep -v '^\[DEBUG\]' | tail -15 | sed 's/^/    /'
    fi
  }
  {
    case $kind in
      typecheck)
        if log=$("$QUINT" typecheck "$dir/model.qnt" 2>&1); then
          echo "ok   $dir typecheck"
        else
          echo "FAIL $dir: typecheck"
          printf '%s\n' "$log" | grep -v '^\[DEBUG\]' | sed 's/^/    /'
        fi ;;
      row) row "$inv" ;;
      holds)
        # $inv is a space-separated list of invariants for this main; check
        # them together, in SHARDS parallel runs with consecutive seeds.
        IFS=' '
        per=$(( (SAMPLES + SHARDS - 1) / SHARDS ))
        k=0 pids=
        while [ $k -lt "$SHARDS" ]; do
          # shellcheck disable=SC2086
          "$QUINT" run --main="$main" --invariants $inv \
            --max-samples="$per" --max-steps="$STEPS" --seed=$((SEED + k)) \
            "$dir/model.qnt" >/dev/null 2>&1 &
          pids="$pids $!"
          k=$((k + 1))
        done
        k=0 bad=
        for p in $pids; do
          wait "$p" || { [ -n "$bad" ] || bad=$((SEED + k)); }
          k=$((k + 1))
        done
        if [ -z "$bad" ]; then
          for i in $inv; do echo "ok   $dir $main.$i (holds)"; done
        else
          # re-run each invariant on the failing shard to say which one broke
          for i in $inv; do row "$i" "$bad" "$per"; done
        fi ;;
      witness)
        if log=$("$QUINT" test --backend=typescript --main=witnesses --match='Test$' \
               "$dir/witnesses.qnt" 2>&1); then
          echo "ok   $dir witnesses: $(printf '%s\n' "$log" | grep -c '^ *ok ') passed"
        else
          echo "FAIL $dir witnesses"
          printf '%s\n' "$log" | grep -v '^\[DEBUG\]' | grep -vE '^ *ok ' | tail -25 | sed 's/^/    /'
        fi ;;
      mutant)
        # $inv is the mutants.tsv line number; run on a copy of spec/.
        line=$(sed -n "${inv}p" "$dir/mutants.tsv")
        mfile=$(printf '%s' "$line" | cut -f1)
        medit=$(printf '%s' "$line" | cut -f2)
        mmain=$(printf '%s' "$line" | cut -f3)
        minv=$(printf '%s' "$line" | cut -f4)
        mdesc=$(printf '%s' "$line" | cut -f5)
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-mutant.XXXXXX")
        cp -R spec "$tmp/spec"
        sed -e "$medit" "$dir/$mfile" > "$tmp/$dir/$mfile"
        if cmp -s "$dir/$mfile" "$tmp/$dir/$mfile"; then
          echo "FAIL $dir mutant \"$mdesc\": the edit did not change $mfile"
        else
          log=$("$QUINT" run --main="$mmain" --invariant="$minv" \
            --max-samples="$SAMPLES" --max-steps="$STEPS" --seed="$SEED" \
            "$tmp/$dir/model.qnt" 2>&1)
          if printf '%s' "$log" | grep -q '^\[violation\]'; then
            echo "ok   $dir mutant caught by $mmain.$minv: $mdesc"
          else
            echo "FAIL $dir mutant survived ($mmain.$minv): $mdesc"
            printf '%s\n' "$log" | grep -v '^\[DEBUG\]' | tail -5 | sed 's/^/    /'
          fi
        fi
        rm -rf "$tmp" ;;
      conform-negative)
        if log=$(QUINT="$QUINT" sh "$dir/conform.sh" --negative 2>&1); then
          echo "FAIL $dir conformance --negative passed: the harness cannot detect a wrong model"
          printf '%s\n' "$log" | tail -5 | sed 's/^/    /'
        else
          echo "ok   $dir conformance detects a wrong model"
        fi ;;
      conform)
        if log=$(QUINT="$QUINT" sh "$dir/conform.sh" 2>&1); then
          echo "ok   $dir conformance: $(printf '%s' "$log" | tail -1)"
        else
          echo "FAIL $dir conformance"
          printf '%s\n' "$log" | tail -15 | sed 's/^/    /'
        fi ;;
    esac
  } > "$out"
  exit 0
fi

# ---- driver -----------------------------------------------------------
if ! command -v "$QUINT" >/dev/null 2>&1; then
  echo "error: quint not found (use nix develop, or QUINT=...)" >&2
  exit 127
fi

if [ $# -eq 0 ]; then
  set -- spec/core/*/ spec/*/ spec/*/proofs/*/
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-check.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

# Run a job list (one tab-separated job per line) in parallel; each job
# writes its result to the file named in its first field.
run_jobs() {
  xargs -P "$JOBS" -I{} sh "$0" --job "{}" < "$1"
}

# Phase 1: typecheck every model.
n=0
: > "$work/jobs.typecheck"
dirs=
for dir in "$@"; do
  dir=${dir%/}
  [ -f "$dir/model.qnt" ] && [ -f "$dir/checks.tsv" ] || continue
  dirs="$dirs $dir"
  n=$((n + 1))
  printf '%s\t%s\t%s\t-\t-\t-\t-\n' "$work/t$(printf %05d $n)" typecheck "$dir" >> "$work/jobs.typecheck"
done
run_jobs "$work/jobs.typecheck"

# Phase 2: every row and conformance check of the models that typecheck.
# `holds` rows run the full sample budget, so they are queued first.
fail=0
total=0
: > "$work/jobs.rows"
n=0
for dir in $dirs; do
  n=$((n + 1))
  if grep -q '^FAIL' "$work/t$(printf %05d $n)"; then
    fail=$((fail + 1))
    continue
  fi
  # violated rows: one job each
  while IFS="$tab" read -r main inv expect issues; do
    case "$main" in ''|'#'*) continue ;; esac
    total=$((total + 1))
    [ "$expect" = holds ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$expect" "$work/r$(printf %05d $total)" row "$dir" \
      "$main" "$inv" "$expect" "${issues:--}" >> "$work/jobs.rows"
  done < "$dir/checks.tsv"
  # holds rows: one job per main module
  for main in $(awk -F "$tab" '$3 == "holds" { print $1 }' "$dir/checks.tsv" | sort -u); do
    invs=$(awk -F "$tab" -v m="$main" '$1 == m && $3 == "holds" { printf "%s%s", sep, $2; sep = " " }' "$dir/checks.tsv")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' holds "$work/r$(printf %05d $total)h$main" holds "$dir" \
      "$main" "$invs" holds - >> "$work/jobs.rows"
  done
  if [ -f "$dir/conform.sh" ]; then
    for k in conform conform-negative; do
      total=$((total + 1))
      printf '%s\t%s\t%s\t%s\t-\t-\t-\t-\n' holds "$work/r$(printf %05d $total)" $k "$dir" >> "$work/jobs.rows"
    done
  fi
  if [ -f "$dir/witnesses.qnt" ]; then
    total=$((total + 1))
    printf '%s\t%s\t%s\t%s\t-\t-\t-\t-\n' holds "$work/r$(printf %05d $total)" witness "$dir" >> "$work/jobs.rows"
  fi
  if [ -f "$dir/mutants.tsv" ]; then
    ln=0
    while IFS= read -r line; do
      ln=$((ln + 1))
      case "$line" in ''|'#'*) continue ;; esac
      total=$((total + 1))
      printf '%s\t%s\t%s\t%s\t-\t%s\t-\t-\n' holds "$work/r$(printf %05d $total)" mutant "$dir" "$ln" >> "$work/jobs.rows"
    done < "$dir/mutants.tsv"
  fi
  # Coverage (no quint needed): a witness for every issue a violated row
  # names, and reachability runs wherever fixed/proposed instances exist.
  total=$((total + 1))
  cov="$work/r$(printf %05d $total)"
  {
    missing=
    for iss in $(awk -F "$tab" '$3 == "violated" { print $4 }' "$dir/checks.tsv" | tr ',' ' ' | tr -d '#' | tr ' ' '\n' | sort -u); do
      if ! { [ -f "$dir/witnesses.qnt" ] && grep -Eq "run w${iss}[A-Za-z0-9_]*Test" "$dir/witnesses.qnt"; }; then
        missing="$missing #$iss"
      fi
    done
    needs_reach=$(awk -F "$tab" '$1 ~ /^(fixed|proposed)/ { print "yes"; exit }' "$dir/checks.tsv")
    noreach=
    if [ -n "$needs_reach" ] && ! { [ -f "$dir/witnesses.qnt" ] && grep -Eq 'run reach[A-Za-z0-9_]*Test' "$dir/witnesses.qnt"; }; then
      noreach=yes
    fi
    if [ -n "$missing" ]; then echo "FAIL $dir coverage: no witness for$missing"
    elif [ -n "$noreach" ]; then echo "FAIL $dir coverage: fixed/proposed instances have no reach...Test runs"
    else echo "ok   $dir coverage: every issue has a witness"
    fi
  } > "$cov"
done
sort -s -t "$tab" -k1,1 "$work/jobs.rows" | cut -f2- > "$work/jobs.sorted"
run_jobs "$work/jobs.sorted"

# Report in job order: typecheck failures, then every row.
for f in "$work"/t* "$work"/r*; do
  [ -f "$f" ] || continue
  case $f in
    "$work"/t*) if grep -q '^FAIL' "$f"; then cat "$f"; fi ;;
    *) cat "$f"; if grep -q '^FAIL' "$f"; then fail=$((fail + $(grep -c '^FAIL' "$f"))); fi ;;
  esac
done

echo "spec: $total checks, $fail failed"
[ $fail -eq 0 ]
