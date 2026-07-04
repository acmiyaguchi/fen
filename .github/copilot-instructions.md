# Copilot instructions for `fen`

`fen` is a small Fennel→Lua coding-agent CLI.
It mirrors pi-mono's interface shapes in simplified form and targets Lua 5.4 on
ARMv7/Raspberry-Pi-class hardware.
Keep review comments concise and actionable; prefer targeted fixes over broad rewrites.

## Project shape

- Source is **Fennel** (`.fnl`), compiled to Lua. Naming is kebab-case in Fennel
  ↔ camelCase in the pi-mono TypeScript it ports from.
- Sibling checkouts (`pi-mono/`, `dirac/`) are reference-only; PRs should not
  touch them.

## What to flag

### Generated / build artifacts
- Edits to package `dist/` trees or generated `.lua` for Nix binaries. These are
  gitignored and machine-generated — hand edits or check-ins are a bug.
- New `result`/`result-*` symlinks (disposable Nix build links) committed to the repo.

### Hot-reload invariants (primary dev loop is `/reload`)
- New core/util `fen.*` modules should be reloadable; extension modules must list
  themselves in their manifest's `reload-modules`.
- Long-lived state tables must be split from behavior: persistent state in a small
  non-reloadable companion module, rendering/logic in reloadable siblings.
- Cross-module behavior should resolve at call time (`module.fn` lookups), not via
  function locals captured in long-lived state.
- Long work (network, subprocess/file drains, bulk reload/discovery, large scans)
  must stay cooperative — accept/pass a yield callback and yield between chunks so
  the TUI can repaint and handle cancel/quit.
- Registration side effects (commands/tools/fragments/events) must be idempotent —
  clear prior owner registrations or rely on the loader's owner cleanup.

### Core-parsimony guardrails (active core-shrinking program)
- One mechanism per job: prefer the events bus and existing register kinds over new
  hook points, kinds, or queues.
- `main.fnl` is CLI-entry only (arg parse, provider resolution, registration
  bootstrap, subcommands). Runtime orchestration belongs in named modules.
- A helper used by two or more extensions belongs in `fen.util.*`, not copy-pasted.
- New streaming providers must build on the shared provider skeleton, not a new copy
  of the transport spine.
- Doc data and provider transport policy stay out of `packages/core`.

### Conventions and dependencies
- All HTTP goes through `fen.util.http.request` and the in-tree `fen_http.so`.
  Flag any reintroduction of `lua-curl`.
- The TUI uses termbox2. Flag any reintroduction of `lcurses`.
- Launcher scripts are POSIX `sh` — flag bashisms.
- Built-in tools stay POSIX-oriented: `edit` is exact-byte match; `grep`/`find`
  shell out to system tools.
- Extension state/registries live in `fen.core.extensions.state`; behavior lives in
  reloadable `fen.core.extensions.*` modules.

### Tests and docs
- Tests run under Busted with Fennel loading; extend `fennel.path` (not
  `package.path`) for `.fnl` roots, and mock modules via `package.loaded` before
  requiring the module under test.
- Behavior changes should update the relevant `docs/` page. Markdown prefers one
  sentence per line.
