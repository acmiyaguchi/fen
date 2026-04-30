#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${FEN_ROCK_VERSION:-1}
REVISION=${FEN_ROCK_REVISION:-1}
ROCKVER="$VERSION-$REVISION"
URL=${FEN_SOURCE_URL:-git+https://github.com/acmiyaguchi/fen.git}

packages='packages/util:fen-util
packages/core:fen-core
packages/providers/openai:fen-provider-openai
packages/providers/openai-codex:fen-provider-openai-codex
packages/providers/anthropic:fen-provider-anthropic
packages/extensions/builtin-tools:fen-ext-builtin-tools
packages/extensions/builtin-commands:fen-ext-builtin-commands
packages/extensions/default-prompt:fen-ext-default-prompt
packages/extensions/tui:fen-ext-tui
packages/extensions/mem:fen-ext-mem
packages/extensions/skills:fen-ext-skills
packages/extensions/agent-state:fen-ext-agent-state
packages/extensions/handoff:fen-ext-handoff
packages/fen:fen'

summary_for() {
  case "$1" in
    fen) echo 'Kitchen-sink fen CLI rock' ;;
    fen-core) echo 'fen core agent, prompt, session, LLM, and extension APIs' ;;
    fen-util) echo 'fen utility modules' ;;
    fen-provider-*) echo 'fen LLM provider package' ;;
    fen-ext-*) echo 'fen first-party extension package' ;;
    *) echo 'fen package' ;;
  esac
}

emit_deps() {
  deps=$1
  echo 'dependencies = {'
  if [ -f "$deps" ]; then
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$dep" in \#*) continue;; esac
      printf '   %s,\n' "$(printf '%s' "$dep" | sed "s/'/\\\\'/g; s/^/\"/; s/$/\"/")"
    done < "$deps"
  else
    echo '   "lua >= 5.4",'
  fi
  echo '}'
}

module_name_for() {
  rel=$1
  rel=${rel#src/}
  rel=${rel%.fnl}
  case "$rel" in */init) rel=${rel%/init};; esac
  printf '%s' "$rel" | tr '/' '.'
}

emit_modules() {
  pkgdir=$1
  rock=$2
  echo '   modules = {'
  find "$pkgdir/src" -name '*.fnl' | sort | while IFS= read -r file; do
    rel=${file#"$pkgdir/"}
    mod=$(module_name_for "$rel")
    lua="dist/${rel#src/}"
    lua=${lua%.fnl}.lua
    printf '      ["%s"] = "%s",\n' "$mod" "$lua"
  done
  if [ "$rock" = fen ]; then
    printf '      ["fen.version"] = "dist/fen/version.lua",\n'
  fi
  if [ "$rock" = fen-ext-tui ]; then
    cat <<'EOF'
      termbox2 = {
         sources = { "vendor/lua_termbox2.c" },
         incdirs = { "vendor" },
      },
EOF
  fi
  echo '   },'
}

printf '%s\n' "$packages" | while IFS=: read -r rel rock; do
  pkgdir="$ROOT/$rel"
  [ -d "$pkgdir/src" ] || { echo "missing package src: $rel" >&2; exit 1; }
  out="$pkgdir/$rock-$ROCKVER.rockspec"
  tmp="$out.tmp"
  {
    printf 'package = "%s"\n' "$rock"
    printf 'version = "%s"\n' "$ROCKVER"
    echo 'rockspec_format = "3.0"'
    echo ''
    echo 'source = {'
    printf '   url = "%s",\n' "$URL"
    printf '   dir = "fen/%s",\n' "$rel"
    echo '}'
    echo ''
    echo 'description = {'
    printf '   summary = "%s",\n' "$(summary_for "$rock")"
    echo '   license = "MIT",'
    echo '}'
    echo ''
    emit_deps "$pkgdir/deps.txt"
    if [ "$rock" = fen-ext-tui ]; then
      cat <<'EOF'

external_dependencies = {
   LUA = { header = "lua.h" },
}
EOF
    fi
    cat <<'EOF'

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "builtin",
EOF
    emit_modules "$pkgdir" "$rock"
    if [ "$rock" = fen ]; then
      cat <<'EOF'
   install = {
      bin = { ["fen"] = "../../bin/fen.lua" },
   },
EOF
    fi
    echo '}'
  } > "$tmp"
  mv "$tmp" "$out"
done
