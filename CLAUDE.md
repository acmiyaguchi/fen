# CLAUDE.md

Project-specific instructions for coding agents working in this repo. See
`README.md` for user docs and `docs/` for maintainer/reference material.

## What this is

`fen` is a small Fennel→Lua coding-agent CLI. It mirrors pi-mono's interface
shapes in simplified form and targets Lua 5.4 on ARMv7/Raspberry-Pi-class
hardware.

The active project is this repo. Sibling checkouts such as `pi-mono/` and
`dirac/` are reference-only unless the user explicitly asks to edit them.

## Must-follow workflow

Normal development uses one Nix-built single-file `fen` binary plus source
overlays. Do not regenerate or edit package `dist/` trees for ordinary `.fnl`
source work.

```sh
make dev-nix                        # nix build .#fen, then scripts/dev/fen-dev
# or, if FEN_BIN is set / fen is on PATH:
make dev
# edit .fnl, then /reload in the running TUI
```

Fast checks while editing:

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=path/to/test.fnl    # focused test
make test                           # full Busted suite
make check                          # fennel-check + tests
```

Use Nix for reproducible/binary validation:

```sh
nix build .#fen
nix flake check
```

`nix build` may leave `result`, `result-1`, or named `result-*` symlinks in the
repo root. They are disposable links into `/nix/store`; remove them with
`rm -f result result-*` or avoid creating them with `nix build .#fen --no-link`.

## Hot reload invariants

`/reload` is the primary iteration loop. `scripts/dev/fen-dev` sets `FEN_DEV_PATH` and
`FEN_EXTENSION_ROOT`, so changed `.fnl` source is loaded directly from the
checkout.

Rules for new code:

- **Default to reloadable.** Add normal behavior modules to `RELOADABLE` in
  `packages/fen/src/fen/main.fnl`.
- **Split persistent state from behavior.** Long-lived state tables belong in a
  small non-reloadable companion module; rendering/logic belongs in reloadable
  siblings.
- **Resolve cross-module behavior at call time.** Prefer `module.fn` lookups over
  captured function locals in long-lived state.
- **Keep long work cooperative.** Network calls, subprocess/file drains, bulk
  reload/discovery, and large scans should accept/pass a yield callback and
  yield between chunks so the TUI can repaint and process cancel/quit keys.
- **Make registration side effects idempotent.** Reloadable modules or extension
  entries that register commands/tools/fragments/events must clear prior owner
  registrations or rely on the loader's owner cleanup.

Persistent identity modules include `fen.extensions.tui.state`,
`fen.core.extensions.state`, and `fen.main`. Do not casually add stateful modules
outside reload without a clear reason.

## Critical gotchas

- Markdown docs prefer one sentence per line where practical; this keeps diffs,
  review, and future trimming easier.
- Generated `.lua` for Nix-built binaries lands in package `dist/` trees inside
  build sandboxes. Local `dist/` trees are gitignored; do not check them in or
  hand-edit them.
- Tests run under busted with Fennel loading. Extend `fennel.path`, not
  `package.path`, for `.fnl` source roots.
- Mock modules in tests via `package.loaded` before requiring the module under
  test.
- All HTTP goes through `fen.util.http.request` and the in-tree `fen_http.so`
  binding. Do not reintroduce `lua-curl`.
- Do not reintroduce `lcurses`; the TUI uses termbox2.
- Launcher scripts are POSIX `sh`; avoid bashisms.
- Built-in tools intentionally stay POSIX-oriented. `edit` is exact-byte match;
  `grep`/`find` shell out to system tools.
- Extension state/registries live in `fen.core.extensions.state`; behavior lives
  in reloadable `fen.core.extensions.*` modules.

## Docs map

- `docs/development.md` — dev workflow, hot reload, checks, Nix result symlinks.
- `docs/architecture.md` — module map, canonical types, core API philosophy,
  implementation gotchas.
- `docs/extensions.md` — extension discovery, manifests, API surface, reload,
  packaging, examples.
- `docs/providers.md` — provider interface, auth/wire differences,
  `models.json` custom providers.
- `docs/tools.md` — built-in tool contracts and deliberate omissions.
- `docs/sessions.md` — JSONL session format and flags.
- `docs/scripts.md` — portable Lua/Fennel script runner.
- `docs/skills.md` — SKILL.md discovery and prompt behavior.
- `docs/distribution.md` — Nix artifacts, releases, cross builds, Docker smoke.
- `docs/single-file.md` — embedded-archive launcher, `package.searchers`
  precedence, dev-overlay flags.
- `docs/roadmap.md` — tracked work and intentional out-of-scope items.

Prefer updating the relevant `docs/` page for stable reference material; keep
this file short and focused on what an agent must know before editing.
