#!/usr/bin/env sh
# Move on-disk state from the old `agent-fennel` name to `fen`. Idempotent:
# missing source dirs are silently skipped, and the script refuses to
# clobber an already-existing destination.
#
# Project-local dirs (`./.agent-fennel/skills`, `./.agent-fennel/SYSTEM.md`)
# live per-repo and are NOT migrated automatically. Run this in each project
# that has them: `mv .agent-fennel .fen`.

set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
Usage: scripts/migrate-rename.sh

Renames agent-fennel state directories to fen:
  ~/.config/agent-fennel       -> ~/.config/fen
  ~/.local/state/agent-fennel  -> ~/.local/state/fen

Project-local `.agent-fennel/` dirs (per-repo SYSTEM.md / skills overlays)
are NOT migrated by this script. Inside any project that has them, run:
  mv .agent-fennel .fen
EOF
  exit 0
fi

XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
XDG_STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}

migrate() {
  src=$1
  dst=$2
  if [ ! -e "$src" ]; then
    return 0
  fi
  if [ -e "$dst" ]; then
    printf 'skip: %s exists; not overwriting\n' "$dst" >&2
    return 0
  fi
  mv -- "$src" "$dst"
  printf 'moved: %s -> %s\n' "$src" "$dst"
}

migrate "$XDG_CONFIG_HOME/agent-fennel" "$XDG_CONFIG_HOME/fen"
migrate "$XDG_STATE_HOME/agent-fennel"  "$XDG_STATE_HOME/fen"
