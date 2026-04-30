#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

owner_for() {
  mod=$1
  case "$mod" in
    fen.main|fen.version) echo fen ;;
    fen.util|fen.util.*) echo fen-util ;;
    fen.core|fen.core.*) echo fen-core ;;
    fen.providers.openai_completions) echo fen-provider-openai ;;
    fen.providers.openai_responses|fen.providers.openai_responses_shared|fen.providers.openai_codex_responses|fen.providers.openai_codex_oauth|fen.providers.openai_codex_keychain) echo fen-provider-openai-codex ;;
    fen.providers.anthropic_messages) echo fen-provider-anthropic ;;
    fen.extensions.builtin_tools|fen.extensions.builtin_tools.*) echo fen-ext-builtin-tools ;;
    fen.extensions.builtin_commands|fen.extensions.builtin_commands.*) echo fen-ext-builtin-commands ;;
    fen.extensions.default_prompt|fen.extensions.default_prompt.*) echo fen-ext-default-prompt ;;
    fen.extensions.tui|fen.extensions.tui.*) echo fen-ext-tui ;;
    fen.extensions.mem|fen.extensions.mem.*) echo fen-ext-mem ;;
    fen.extensions.skills|fen.extensions.skills.*) echo fen-ext-skills ;;
    fen.extensions.agent_state|fen.extensions.agent_state.*) echo fen-ext-agent-state ;;
    fen.extensions.handoff|fen.extensions.handoff.*) echo fen-ext-handoff ;;
    *) echo '' ;;
  esac
}

pkg_for_dir() {
  d=$1
  rockspec=$(find "$d" -maxdepth 1 -name '*.rockspec' | sort | head -1)
  sed -n 's/^package = "\([^"]*\)"/\1/p' "$rockspec" | head -1
}

has_dep() {
  rockspec=$1
  dep=$2
  grep -Eq '"'"$dep"'([ <>=,~"]|$)' "$rockspec"
}

allowed_external() {
  case "$1" in
    cjson|cURL|fennel|termbox2|posix|posix.*|test_helpers|tool_test_helpers) return 0;;
    *) return 1;;
  esac
}

rc=0
find "$ROOT/packages" -mindepth 1 -maxdepth 3 -type d -name src -prune | sort | while IFS= read -r src; do
  pkgdir=${src%/src}
  pkg=$(pkg_for_dir "$pkgdir")
  rockspec=$(find "$pkgdir" -maxdepth 1 -name '*.rockspec' | sort | head -1)
  [ -n "$pkg" ] || continue
  tmp=$(mktemp)
  find "$src" -name '*.fnl' -print0 | xargs -0 perl -ne 'while(/\(require\s+:([A-Za-z0-9_.-]+)/g){print "$1\n"} while(/pcall\s+require\s+:([A-Za-z0-9_.-]+)/g){print "$1\n"}' | sort -u > "$tmp"
  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    if allowed_external "$mod"; then continue; fi
    owner=$(owner_for "$mod")
    if [ -z "$owner" ]; then
      echo "unknown require owner: $pkg requires $mod" >&2
      rc=1
      continue
    fi
    [ "$owner" = "$pkg" ] && continue
    if has_dep "$rockspec" "$owner"; then continue; fi
    echo "missing dependency: $pkg requires $mod (owned by $owner)" >&2
    rc=1
  done < "$tmp"
  rm -f "$tmp"
done
exit "$rc"
