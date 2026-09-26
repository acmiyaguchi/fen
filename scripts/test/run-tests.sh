#!/bin/sh
set -eu

missing=0
for cmd in fennel busted; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "run-tests: missing $cmd" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "run-tests: install dev deps (for example: nix develop, or luarocks --lua-version=5.4 install fennel busted lua-cjson luasocket luafilesystem)" >&2
  exit 127
fi

# Tests exercise native helpers directly (fen_http.so) and indirectly via
# cooperative bash/process I/O (fen_process.so). Keep this script self-contained
# so `make test` works from a source checkout after `make clean` / without a
# prior Nix build step.
need_pty=0
case " ${FEN_BUILD_PTY_HELPER:-} ${FEN_INCLUDE_SMOKE_TESTS:-0} $* " in
  *" 1 "*|*"extensions/adapters/presenters/tui/tests/smoke/pty_test.fnl"*) need_pty=1 ;;
esac

CC=${CC:-cc}
CFLAGS=${CFLAGS:-"-O2 -fPIC -Wall"}
LUA_INCDIR=${LUA_INCDIR:-/usr/include/lua5.4}
CURL_INCDIR=${CURL_INCDIR:-}
CURL_LIBDIR=${CURL_LIBDIR:-}

TERMBOX_SO=extensions/adapters/presenters/tui/dist/termbox2.so
FEN_HTTP_SO=packages/util/dist/fen_http.so
FEN_PROCESS_SO=packages/util/dist/fen_process.so
FEN_RANDOM_SO=packages/util/dist/fen_random.so
FEN_PTY_SO=packages/testing/dist/fen_pty.so

# Rebuild a native module when its .so is missing or when any of the C sources
# and headers it is compiled from is newer than the .so. `test -nt` is POSIX
# (POSIX.1-2024) and keeps `make test` honest after editing vendored C without
# a separate Nix build step.
needs_rebuild() {
  so=$1
  shift
  [ -f "$so" ] || return 0
  for src do
    [ "$src" -nt "$so" ] && return 0
  done
  return 1
}

CURL_INC_FLAG=
CURL_LIB_FLAG=
if [ -n "$CURL_INCDIR" ]; then
  CURL_INC_FLAG="-I$CURL_INCDIR"
fi
if [ -n "$CURL_LIBDIR" ]; then
  CURL_LIB_FLAG="-L$CURL_LIBDIR"
fi

if needs_rebuild "$TERMBOX_SO" \
  extensions/adapters/presenters/tui/vendor/lua_termbox2.c \
  extensions/adapters/presenters/tui/vendor/termbox2.h; then
  echo "run-tests: building $TERMBOX_SO" >&2
  mkdir -p "$(dirname "$TERMBOX_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    -Iextensions/adapters/presenters/tui/vendor \
    -shared extensions/adapters/presenters/tui/vendor/lua_termbox2.c \
    -o "$TERMBOX_SO"
fi

if needs_rebuild "$FEN_HTTP_SO" packages/util/vendor/fen_http.c; then
  echo "run-tests: building $FEN_HTTP_SO" >&2
  mkdir -p "$(dirname "$FEN_HTTP_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    $CURL_INC_FLAG \
    -shared packages/util/vendor/fen_http.c \
    $CURL_LIB_FLAG \
    -lcurl \
    -o "$FEN_HTTP_SO"
fi

if needs_rebuild "$FEN_PROCESS_SO" packages/util/vendor/fen_process.c; then
  echo "run-tests: building $FEN_PROCESS_SO" >&2
  mkdir -p "$(dirname "$FEN_PROCESS_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    -shared packages/util/vendor/fen_process.c \
    -o "$FEN_PROCESS_SO"
fi

if needs_rebuild "$FEN_RANDOM_SO" packages/util/vendor/fen_random.c; then
  echo "run-tests: building $FEN_RANDOM_SO" >&2
  mkdir -p "$(dirname "$FEN_RANDOM_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    -shared packages/util/vendor/fen_random.c \
    -o "$FEN_RANDOM_SO"
fi

if [ "$need_pty" -eq 1 ] && needs_rebuild "$FEN_PTY_SO" packages/testing/vendor/fen_pty.c; then
  echo "run-tests: building $FEN_PTY_SO" >&2
  mkdir -p "$(dirname "$FEN_PTY_SO")"
  # shellcheck disable=SC2086
  $CC $CFLAGS \
    -I"$LUA_INCDIR" \
    -shared packages/testing/vendor/fen_pty.c \
    -lutil \
    -o "$FEN_PTY_SO"
fi

# Isolate every run from the developer's real XDG state/config/data/cache and
# HOME: tests write diagnostics, sessions, and error logs, and concurrent runs
# in sibling worktrees must not read each other's files. The Fennel compile
# cache is resolved first so it stays shared and warm across runs.
FEN_TEST_COMPILE_CACHE_DIR=${FEN_TEST_COMPILE_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/fen/fennel-compile-cache}
FEN_TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fen-test-home.XXXXXX")
trap 'rm -rf "$FEN_TEST_HOME"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
HOME=$FEN_TEST_HOME/home
XDG_CONFIG_HOME=$FEN_TEST_HOME/config
XDG_STATE_HOME=$FEN_TEST_HOME/state
XDG_DATA_HOME=$FEN_TEST_HOME/data
XDG_CACHE_HOME=$FEN_TEST_HOME/cache
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
export FEN_TEST_COMPILE_CACHE_DIR FEN_TEST_HOME HOME \
  XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME

# Runs busted and exits with its status; not exec, so the EXIT trap removes
# the isolated home.
run_busted() {
  # BUSTED_ARGS is intentionally shell-split so maintainers can pass normal
  # busted options such as BUSTED_ARGS='--filter=foo --shuffle'. Keep test
  # paths in TESTS/positional args when they may contain shell metacharacters.
  if [ -n "${BUSTED_ARGS:-}" ]; then
    # shellcheck disable=SC2086
    busted --loaders=lua,fennel --helper=scripts/test/busted-helper.lua --pattern=_test $BUSTED_ARGS "$@"
  else
    busted --loaders=lua,fennel --helper=scripts/test/busted-helper.lua --pattern=_test "$@"
  fi
}

default_jobs() {
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  echo "$n"
}

exec_busted() {
  # Run multi-file selections on FEN_TEST_JOBS workers (default: one per CPU).
  # Files are dealt into small chunks that workers claim with an atomic mkdir,
  # so a few slow files cannot pile up on one worker. Each worker has its own
  # HOME/XDG tree, and output is printed whole, per worker, once all finish.
  jobs=${FEN_TEST_JOBS:-$(default_jobs)}
  if [ "$jobs" -gt "$#" ]; then jobs=$#; fi
  if [ "$jobs" -le 1 ]; then
    status=0
    run_busted "$@" || status=$?
    exit "$status"
  fi

  chunks=$((jobs * 4))
  i=0
  for f do
    printf '%s\n' "$f" >>"$FEN_TEST_HOME/chunk-$((i % chunks)).list"
    i=$((i + 1))
  done

  pids=
  trap 'kill $pids 2>/dev/null' INT TERM
  n=0
  while [ "$n" -lt "$jobs" ]; do
    worker=$FEN_TEST_HOME/worker-$n
    (
      HOME=$worker/home
      XDG_CONFIG_HOME=$worker/config
      XDG_STATE_HOME=$worker/state
      XDG_DATA_HOME=$worker/data
      XDG_CACHE_HOME=$worker/cache
      mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
      worker_status=0
      c=0
      while [ "$c" -lt "$chunks" ]; do
        chunk=$FEN_TEST_HOME/chunk-$c
        if [ -f "$chunk.list" ] && mkdir "$chunk.claim" 2>/dev/null; then
          # shellcheck disable=SC2046
          run_busted $(cat "$chunk.list") || worker_status=$?
        fi
        c=$((c + 1))
      done
      exit "$worker_status"
    ) >"$worker.out" 2>&1 &
    pids="$pids $!"
    n=$((n + 1))
  done

  status=0
  n=0
  for pid in $pids; do
    wait "$pid" || status=$?
    cat "$FEN_TEST_HOME/worker-$n.out"
    n=$((n + 1))
  done
  # Busted prints one summary per chunk; add the combined total.
  cat "$FEN_TEST_HOME"/worker-*.out | awk '
    / successes \/ .* failures? \/ .* errors? \/ .* pending/ {
      ok += $1; bad += $4; err += $7; pend += $10; secs += $13
    }
    END { printf "run-tests: %d successes / %d failures / %d errors / %d pending : %.1f busted-seconds across '"$jobs"' workers\n", ok, bad, err, pend, secs }'
  exit "$status"
}

exec_test_roots() {
  # Keep directory-focused runs aligned with default `make test`: a directory
  # root such as TESTS=extensions/adapters/presenters/tui/tests should not
  # accidentally pick up opt-in smoke tests. Explicit smoke files still run.
  if [ "${FEN_INCLUDE_SMOKE_TESTS:-0}" = 1 ]; then
    exec_busted "$@"
  fi

  expanded=
  for root do
    if [ -d "$root" ]; then
      found=$(find "$root" -type f -name '*_test.fnl' ! -path '*/tests/smoke/*' | sort)
      if [ -n "$found" ]; then
        expanded="$expanded $found"
      fi
    else
      expanded="$expanded $root"
    fi
  done

  if [ -n "$expanded" ]; then
    # shellcheck disable=SC2086
    exec_busted $expanded
  else
    exec_busted "$@"
  fi
}

if [ "$#" -gt 0 ]; then
  exec_test_roots "$@"
else
  # Keep opt-in smoke suites (notably the real-PTY TUI smoke) out of the
  # ordinary unit/integration pass; dedicated make targets pass those files
  # explicitly and enable any extra native helpers they need.
  if [ "${FEN_INCLUDE_SMOKE_TESTS:-0}" = 1 ]; then
    tests=$(find packages extensions -type f -name '*_test.fnl' | sort)
  else
    tests=$(find packages extensions -type f -name '*_test.fnl' ! -path '*/tests/smoke/*' | sort)
  fi
  # shellcheck disable=SC2086
  exec_busted $tests
fi
