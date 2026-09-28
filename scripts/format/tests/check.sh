#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fen-format-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts/format/vendor" "$tmp/src"
cp "$root/scripts/format/check.fnl" "$tmp/scripts/format/check.fnl"
cp "$root/scripts/format/vendor/fnlfmt.fnl" "$tmp/scripts/format/vendor/fnlfmt.fnl"
cd "$tmp"
git init -q
git config user.email format-test@example.invalid
git config user.name 'Format Test'
unformatted='(local x (do (print :a) (print :b)))'
fmt() { fennel scripts/format/check.fnl "$@"; }
expect_status() {
  want=$1
  shift
  set +e
  "$@" >"$tmp/out.log" 2>&1
  got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    echo "expected exit $want, got $got: $*" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
}

cat > 'src/shebang with spaces.fnl' <<EOF
#!/usr/bin/env fennel
$unformatted
EOF
fmt --fix 'src/shebang with spaces.fnl' >/dev/null
[ "$(head -n 1 'src/shebang with spaces.fnl')" = '#!/usr/bin/env fennel' ]
fmt 'src/shebang with spaces.fnl'
cp 'src/shebang with spaces.fnl' "$tmp/stable"
fmt --fix 'src/shebang with spaces.fnl' >/dev/null
cmp "$tmp/stable" 'src/shebang with spaces.fnl'

# A CRLF shebang line survives formatting byte for byte.
printf '#!/usr/bin/env fennel\r\n(local x 1)\r\n' > src/crlf.fnl
fmt --fix src/crlf.fnl >/dev/null
[ "$(head -n 1 src/crlf.fnl)" = "$(printf '#!/usr/bin/env fennel\r')" ]
fmt src/crlf.fnl
git add src
git commit -qm baseline

# Usage errors exit 2 instead of silently passing.
expect_status 2 fmt
expect_status 2 fmt --fix --staged
expect_status 2 fmt --chek src/crlf.fnl
expect_status 2 fmt --changed no-such-ref

# A staged unformatted file fails even when the worktree has been fixed.
printf '%s\n' "$unformatted" > 'src/shebang with spaces.fnl'
git add 'src/shebang with spaces.fnl'
fmt --fix 'src/shebang with spaces.fnl' >/dev/null
expect_status 1 fmt --staged
grep -q 'Not formatted: src/shebang with spaces.fnl' "$tmp/out.log"
git add 'src/shebang with spaces.fnl'
fmt --staged
git commit -qm formatted

# The changed-files gate selects only the current change; it does not require
# a repo-wide baseline to have already been formatted. It sees committed,
# uncommitted, and untracked changes, and works from a subdirectory.
printf '%s\n' "$unformatted" > src/committed.fnl
git add src/committed.fnl
git commit -qm unformatted
printf '%s\n' "$unformatted" > src/untracked.fnl
printf '%s\n' "$unformatted" > src/unchanged-base.fnl
git add src/unchanged-base.fnl
git commit -qm 'unformatted base'
git tag base
printf '%s\n' "$unformatted" > src/committed-after.fnl
git add src/committed-after.fnl
git commit -qm 'after base'
expect_status 1 fmt --changed base
grep -q 'Not formatted: src/committed-after.fnl' "$tmp/out.log"
grep -q 'Not formatted: src/untracked.fnl' "$tmp/out.log"
if grep -q 'unchanged-base' "$tmp/out.log"; then
  echo 'expected --changed to skip files unchanged since the base' >&2
  exit 1
fi
(cd src && fennel ../scripts/format/check.fnl --fix --changed base >/dev/null)
fmt --changed base
echo 'format tests: OK'
