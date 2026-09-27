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

cat > 'src/shebang with spaces.fnl' <<'EOF'
#!/usr/bin/env fennel
(local x (do (print :a) (print :b)))
EOF
fennel scripts/format/check.fnl --fix 'src/shebang with spaces.fnl' >/dev/null
[ "$(head -n 1 'src/shebang with spaces.fnl')" = '#!/usr/bin/env fennel' ]
fennel scripts/format/check.fnl --check 'src/shebang with spaces.fnl'
cp 'src/shebang with spaces.fnl' "$tmp/stable"
fennel scripts/format/check.fnl --fix 'src/shebang with spaces.fnl' >/dev/null
cmp "$tmp/stable" 'src/shebang with spaces.fnl'
git add 'src/shebang with spaces.fnl'
git commit -qm baseline

# A staged unformatted file fails even when the worktree has been fixed.
printf '(local x (do (print :a) (print :b)))\n' > 'src/shebang with spaces.fnl'
git add 'src/shebang with spaces.fnl'
fennel scripts/format/check.fnl --fix 'src/shebang with spaces.fnl' >/dev/null
if fennel scripts/format/check.fnl --staged >"$tmp/staged.log" 2>&1; then
  echo 'expected the staged check to reject unformatted index content' >&2
  exit 1
fi
grep -q 'Not formatted: src/shebang with spaces.fnl' "$tmp/staged.log"
git add 'src/shebang with spaces.fnl'
fennel scripts/format/check.fnl --staged

# The changed-files gate selects only the current change; it does not require
# a repo-wide baseline to have already been formatted.
git commit -qm formatted
printf '(local x (do (print :a) (print :b)))\n' > src/added.fnl
git add src/added.fnl
git commit -qm unformatted
if fennel scripts/format/check.fnl --changed HEAD^ >"$tmp/changed.log" 2>&1; then
  echo 'expected CI mode to reject the unformatted changed file' >&2
  exit 1
fi
grep -q 'Not formatted: src/added.fnl' "$tmp/changed.log"
fennel scripts/format/check.fnl --fix src/added.fnl >/dev/null
fennel scripts/format/check.fnl --changed HEAD^
echo 'format tests: OK'
