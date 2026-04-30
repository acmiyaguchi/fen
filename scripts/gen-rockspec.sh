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

deps_for() {
  case "$1" in
    fen-util) printf '%s\n' 'lua >= 5.4' 'lua-cjson >= 2.1' 'lua-curl >= 0.3' 'fennel >= 1.4' ;;
    fen-core) printf '%s\n' 'lua >= 5.4' 'fen-util >= 1-1' ;;
    fen-provider-openai|fen-provider-openai-codex|fen-provider-anthropic) printf '%s\n' 'lua >= 5.4' 'fen-core >= 1-1' 'fen-util >= 1-1' ;;
    fen-ext-builtin-tools|fen-ext-builtin-commands|fen-ext-skills|fen-ext-agent-state) printf '%s\n' 'lua >= 5.4' 'fen-core >= 1-1' 'fen-util >= 1-1' ;;
    fen-ext-tui) printf '%s\n' 'lua >= 5.4' 'fen-core >= 1-1' 'fen-util >= 1-1' 'luaposix >= 36' ;;
    fen-ext-default-prompt|fen-ext-mem|fen-ext-handoff) printf '%s\n' 'lua >= 5.4' 'fen-core >= 1-1' ;;
    fen) printf '%s\n' 'lua >= 5.4' 'fen-core >= 1-1' 'fen-util >= 1-1' 'fen-provider-openai >= 1-1' 'fen-provider-openai-codex >= 1-1' 'fen-provider-anthropic >= 1-1' 'fen-ext-builtin-tools >= 1-1' 'fen-ext-builtin-commands >= 1-1' 'fen-ext-default-prompt >= 1-1' 'fen-ext-tui >= 1-1' 'fen-ext-mem >= 1-1' 'fen-ext-skills >= 1-1' 'fen-ext-agent-state >= 1-1' 'fen-ext-handoff >= 1-1' ;;
    *) printf '%s\n' 'lua >= 5.4' ;;
  esac
}

emit_deps() {
  echo 'dependencies = {'
  deps_for "$1" | while IFS= read -r dep; do
    printf '   "%s",\n' "$dep"
  done
  echo '}'
}

module_name_for() {
  rel=$1
  rel=${rel#src/}
  rel=${rel%.fnl}
  case "$rel" in */init) rel=${rel%/init};; esac
  printf '%s' "$rel" | tr '/' '.'
}

built_path_for() {
  rel=$1
  rel=${rel#src/}
  printf '.luarocks-build/%s.lua' "${rel%.fnl}"
}

emit_build_command() {
  pkgdir=$1
  rock=$2
  echo '   build_command = [['
  echo 'set -eu'
  echo 'rm -rf .luarocks-build'
  echo 'PATH="$(SCRIPTS_DIR):$PATH"'
  find "$pkgdir/src" -name '*.fnl' | sort | while IFS= read -r file; do
    rel=${file#"$pkgdir/"}
    out=$(built_path_for "$rel")
    dir=${out%/*}
    printf 'mkdir -p %s\n' "$dir"
    printf 'fennel --compile %s > %s\n' "$rel" "$out"
  done
  if [ "$rock" = fen ]; then
    echo 'mkdir -p .luarocks-build/fen'
    echo 'printf '\''return "%s"\n'\'' "${FEN_VERSION:-unknown}" > .luarocks-build/fen/version.lua'
  fi
  if [ "$rock" = fen-ext-tui ]; then
    echo 'mkdir -p .luarocks-build'
    echo '$(CC) $(CFLAGS) -I$(LUA_INCDIR) -Ivendor -shared vendor/lua_termbox2.c -o .luarocks-build/termbox2.so'
  fi
  echo '   ]],'
}

emit_install_table() {
  pkgdir=$1
  rock=$2
  echo '   install = {'
  echo '      lua = {'
  find "$pkgdir/src" -name '*.fnl' | sort | while IFS= read -r file; do
    rel=${file#"$pkgdir/"}
    mod=$(module_name_for "$rel")
    built=$(built_path_for "$rel")
    printf '         ["%s"] = "%s",\n' "$mod" "$built"
  done
  if [ "$rock" = fen ]; then
    echo '         ["fen.version"] = ".luarocks-build/fen/version.lua",'
  fi
  echo '      },'
  if [ "$rock" = fen-ext-tui ]; then
    cat <<'EOF'
      lib = {
         ["termbox2"] = ".luarocks-build/termbox2.so",
      },
EOF
  fi
  if [ "$rock" = fen ]; then
    cat <<'EOF'
      bin = {
         ["fen"] = "../../bin/fen.lua",
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
    emit_deps "$rock"
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
   type = "command",
EOF
    emit_build_command "$pkgdir" "$rock"
    emit_install_table "$pkgdir" "$rock"
    echo '}'
  } > "$tmp"
  mv "$tmp" "$out"
done
