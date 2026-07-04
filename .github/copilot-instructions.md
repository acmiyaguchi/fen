# Copilot instructions for `fen`

`fen` is a small Fennel→Lua coding-agent CLI.
It mirrors pi-mono's interface shapes in simplified form and targets Lua 5.4 on
ARMv7/Raspberry-Pi-class hardware.

These are the repo-wide rules that apply to every changed file.
Path-scoped rules that add depth for specific subtrees live in
`.github/instructions/*.instructions.md` and are layered on top automatically.

Keep review comments concise and actionable.
Prefer targeted fixes over broad rewrites; don't request a rewrite unless it is warranted.

## Source model

- Source is **Fennel** (`.fnl`), compiled to Lua.
- Naming is kebab-case in Fennel ↔ camelCase in the pi-mono TypeScript it ports from;
  "what does pi-mono call this?" is a fair question for new interface shapes.

## Never touch

- Package `dist/` trees and any generated `.lua` — they are machine-generated and gitignored.
  Hand edits or check-ins of `dist/` are a bug.
- Committed `result` / `result-*` symlinks (disposable Nix build links).
- Sibling checkouts `pi-mono/` and `dirac/` are reference-only; PRs should not modify them.

## Cross-cutting dependency conventions

These bans hold anywhere in the tree, so flag them regardless of the file under review.

- All HTTP goes through `fen.util.http.request` and the in-tree `fen_http.so` binding.
  Flag any reintroduction of `lua-curl`.
- The TUI uses termbox2. Flag any reintroduction of `lcurses`.
- Launcher/build scripts are POSIX `sh`. Flag bashisms.

## Behavior changes need docs and tests

- A behavior change should update the relevant `docs/` page and carry or update tests.
