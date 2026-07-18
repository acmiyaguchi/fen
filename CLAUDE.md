# CLAUDE.md

Project instructions for coding agents in this repo.
See `README.md` for user docs and `docs/` for maintainer/reference material.

## Project

`fen` is a small Fennel→Lua coding-agent CLI for Lua 5.4 on ARMv7/Raspberry-Pi-class hardware.
This checkout is the active project; sibling checkouts such as `pi-mono/` and `dirac/` are reference-only unless the user asks to edit them.

## Workflow

Develop against a Nix-built single-file `fen` binary plus source overlays.
Do not regenerate or edit package `dist/` trees for normal `.fnl` source work.

```sh
make dev-nix                        # nix build .#fen, then scripts/dev/fen-dev
make dev                            # if FEN_BIN is set or fen is on PATH
# edit .fnl, then /reload in the running TUI
```

Fast checks:

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=path/to/test.fnl
make test
make check
```

Reproducible/binary checks:

```sh
nix build .#fen --no-link
nix flake check
```

`nix build` without `--no-link` may leave disposable `result*` symlinks; remove them with `rm -f result result-*`.
Prefer PRs for reviewable changes, but do not block on optional bot/AI review.
Push directly to `main` only when the user explicitly asks; run `make check` first.

## Hot reload invariants

`/reload` is the main iteration loop.
`scripts/dev/fen-dev` sets `FEN_DEV_PATH` and `FEN_EXTENSION_ROOT`, so changed `.fnl` source loads from the checkout.

- Default to reloadable modules.
  Core/util `fen.*` modules reload automatically; extension modules list themselves in `reload-modules`.
- Keep persistent state in small non-reloadable state modules; keep behavior/rendering reloadable.
- Resolve cross-module behavior at call time (`module.fn`) instead of capturing function locals in long-lived state.
- Pass yield callbacks through network, subprocess/file drains, reload/discovery, and large scans.
- Make registration side effects idempotent or rely on loader owner cleanup.

Persistent identity modules include `fen.extensions.tui.state`, `fen.core.extensions.state`, and `fen.main`.
Do not add stateful modules outside reload without a clear reason.

## Core parsimony

The `core-parsimony` milestone is shrinking architectural core.
Do not widen it while that work is active.

- Prefer the events bus and existing register kinds over new hooks, kinds, or queues.
- Keep `main.fnl` to CLI entry code: args, provider resolution, registration bootstrap, subcommands.
- Move helpers used by two or more extensions to `fen.util.*`.
- Build new streaming providers on the shared provider skeleton.
- Keep doc data and provider transport policy out of `packages/core`.

## Gotchas

- Markdown docs prefer one sentence per line.
- Do not check in generated `.lua`, package `dist/`, or `result*` symlinks.
- Tests run under Busted with Fennel loading; extend `fennel.path`, not `package.path`.
- Mock modules in tests via `package.loaded` before requiring the module under test.
- All HTTP goes through `fen.util.http.request` and `fen_http.so`; do not reintroduce `lua-curl`.
- The TUI uses termbox2; do not reintroduce `lcurses`.
- Launcher scripts are POSIX `sh`; avoid bashisms.
- Built-in tools stay POSIX-oriented; `edit` is exact-byte match, and `grep`/`find` shell out.
- Extension state/registries live in `fen.core.extensions.state`; behavior lives in reloadable `fen.core.extensions.*` modules.

## Docs map

- `docs/development.md` — workflow, reload, checks, contribution flow.
- `docs/architecture.md` — module map, canonical types, design principles.
- `docs/extensions.md` — extension discovery, API, reload, packaging.
- `docs/providers.md` — provider interface and model config.
- `docs/tools.md` — built-in tool contracts.
- `docs/sessions.md` — JSONL session format.
- `docs/scripts.md` — portable Lua/Fennel script runner.
- `docs/skills.md` — skill discovery and prompt behavior.
- `docs/distribution.md` — Nix artifacts and releases.

Prefer updating the relevant `docs/` page for stable reference material; keep this file short.
