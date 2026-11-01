#!/bin/sh
# Proof obligations for the Quint design models, checked with Apalache.
#
# `make check-spec` simulates every checks.tsv row: sampled evidence. This
# script checks only the obligations a spec dir declares in verify.tsv, each a
# proof Apalache can finish:
#
#   <main[@step]> <TAB> <invariants> <TAB> <mode> <TAB> <steps> <TAB> <seconds> <TAB> <why>
#
#   mode bounded    no execution of up to <steps> steps violates <invariants>
#                   (space-separated); `quint verify --max-steps`.
#   mode inductive  <invariants> is one inductive invariant: it holds initially
#                   and every step preserves it, so it holds at any depth;
#                   `quint verify --inductive-invariant`.
#   <seconds>       time budget; exceeding it is reported as `timeout`.
#   <why>           why this bound (or why induction) is enough, e.g. the
#                   length of the known counterexample it must cover.
#
# Each obligation reports one of: bounded-safe, inductive, counterexample,
# unsupported (Apalache rejected the model), timeout, error. Only bounded-safe
# and inductive pass.
#
# Obligations run on SPEC_VERIFY_JOBS lanes (default 4), each with its own
# Apalache server (a JVM with a 4 GB heap, plus Z3).
#
# Usage: sh scripts/spec/verify.sh [spec/<domain> | spec/core/<primitive> ...]
# Env: QUINT, APALACHE (default apalache-mc), SPEC_VERIFY_JOBS,
#      SPEC_VERIFY_PORT (first server port, default 18822).
set -u
QUINT=${QUINT:-quint}
APALACHE=${APALACHE:-apalache-mc}
LANES=${SPEC_VERIFY_JOBS:-4}
PORT0=${SPEC_VERIFY_PORT:-18822}
tab=$(printf '\t')

# ---- lane: one Apalache server, obligations one after another -----------
# Job fields: out dir main invariants mode steps seconds.
if [ "${1-}" = "--lane" ]; then
  port=$2 jobs=$3 work=$4
  log="$work/server-$port.log"
  "$APALACHE" server --port="$port" --out-dir="$work/apalache-$port" > "$log" 2>&1 &
  srv=$!
  trap 'kill "$srv" 2>/dev/null' EXIT INT TERM
  i=0
  until grep -q 'server is running' "$log" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 240 ] || ! kill -0 "$srv" 2>/dev/null; then
      echo "error: Apalache server on port $port did not start" >&2
      tail -5 "$log" >&2
      exit 1
    fi
    sleep 0.5
  done
  if command -v timeout >/dev/null 2>&1; then have_timeout=1; else have_timeout=; fi
  while IFS="$tab" read -r out dir main invs mode steps secs; do
    start=$(date +%s)
    set -f
    IFS=' '
    # shellcheck disable=SC2086
    # main may name a step action: `spec@action` (default `step`).
    stepact=step
    case $main in *@*) stepact=${main#*@}; main=${main%@*} ;; esac
    if [ "$mode" = inductive ]; then
      set -- --inductive-invariant="$invs" --max-steps=1
    else
      set -- --invariants $invs --max-steps="$steps"
    fi
    set -- --step="$stepact" "$@"
    IFS=$tab
    set +f
    if [ -n "$have_timeout" ]; then
      res=$(timeout "$secs" "$QUINT" verify --server-endpoint="localhost:$port" \
              --main="$main" "$@" "$dir/model.qnt" 2>&1)
    else
      res=$("$QUINT" verify --server-endpoint="localhost:$port" \
              --main="$main" "$@" "$dir/model.qnt" 2>&1)
    fi
    status=$?
    took=$(( $(date +%s) - start ))
    if [ $status -eq 0 ]; then
      if [ "$mode" = inductive ]; then got=inductive; else got="bounded-safe ($steps steps)"; fi
    elif [ $status -eq 124 ]; then got="timeout (${secs}s)"
    elif printf '%s' "$res" | grep -q '^\[violation\]'; then got=counterexample
    elif printf '%s' "$res" | grep -qiE 'input error|not supported|unsupported'; then got=unsupported
    else got=error
    fi
    case $got in
      inductive|bounded-safe*) echo "ok   $dir $main: $invs -> $got [${took}s]" ;;
      *)
        echo "FAIL $dir $main: $invs -> $got [${took}s]"
        printf '%s\n' "$res" | grep -v '^\[DEBUG\]' | tail -30 | sed 's/^/    /' ;;
    esac > "$out"
  done < "$jobs"
  exit 0
fi

# ---- driver -------------------------------------------------------------
for tool in "$QUINT" "$APALACHE"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found (use nix develop, or QUINT=/APALACHE=...)" >&2
    exit 127
  fi
done

if [ $# -eq 0 ]; then
  set -- spec/core/*/ spec/core/*/proofs/*/ spec/*/ spec/*/proofs/*/
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fen-spec-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

n=0
: > "$work/jobs"
for dir in "$@"; do
  dir=${dir%/}
  [ -f "$dir/verify.tsv" ] || continue
  while IFS="$tab" read -r main invs mode steps secs why; do
    case "$main" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$work/r$(printf %05d $n)" "$dir" "$main" \
      "$invs" "$mode" "$steps" "$secs" >> "$work/jobs"
  done < "$dir/verify.tsv"
done
if [ $n -eq 0 ]; then
  echo "verify: no obligations (no verify.tsv in the given dirs)"
  exit 0
fi

# Deal obligations round-robin onto lanes and run the lanes in parallel.
k=0
pids=
while [ $k -lt "$LANES" ]; do
  awk -v k=$k -v n="$LANES" '(NR - 1) % n == k' "$work/jobs" > "$work/lane$k"
  if [ -s "$work/lane$k" ]; then
    sh "$0" --lane $((PORT0 + k)) "$work/lane$k" "$work" &
    pids="$pids $!"
  fi
  k=$((k + 1))
done
lanefail=0
for p in $pids; do wait "$p" || lanefail=1; done

fail=0
done_n=0
for f in "$work"/r*; do
  [ -f "$f" ] || continue
  done_n=$((done_n + 1))
  cat "$f"
  fail=$((fail + $(grep -c '^FAIL' "$f")))
done
if [ $done_n -lt $n ]; then
  echo "error: $((n - done_n)) obligation(s) produced no result"
  fail=$((fail + n - done_n))
fi
[ $lanefail -eq 0 ] || fail=$((fail + 1))

echo "verify: $n obligations, $fail failed"
[ $fail -eq 0 ]
