---
name: fen-maintainer
description: Develop, test, and maintain the Fen repository.
user-invocable: true
---

# Fen Maintainer

Use this for maintainer work in `fen`: Fennel source, launcher/dev workflows, docs, tests, extensions, and distribution plumbing.

## Workflow

Develop through the single-file runtime plus source overlays:

```sh
make dev        # uses FEN_BIN or fen on PATH
make dev-nix    # builds .#fen, then runs scripts/dev/fen-dev
```

`scripts/dev/fen-dev` sets `FEN_DEV_PATH` for `packages/{core,util,fen}/src` and `FEN_EXTENSION_ROOT` for `extensions/`.
After editing `.fnl`, use `/reload`; do not rebuild generated Lua just to test source edits.

## Checks

Run the smallest useful check first:

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=path/to/test.fnl
make test BUSTED_ARGS='--filter=foo'
make test
make check
```

Useful test targets:

```sh
make test-list
make test-shuffle REPEAT=3
FEN_INCLUDE_SMOKE_TESTS=1 make test
```

`TESTS` selects files/directories.
`BUSTED_ARGS` is for runner flags such as `--filter`, `--name`, `--tags`, `--shuffle`, `--repeat`, and `--list`.
Directory-focused runs skip `tests/smoke/` unless `FEN_INCLUDE_SMOKE_TESTS=1` is set or a smoke file is passed explicitly.

Use Nix for reproducible/binary validation:

```sh
nix build .#fen --no-link
nix flake check
```

Live-provider smoke when relevant:

```sh
FEN_BIN=/path/to/fen make smoke
```

## TUI tests

Fast deterministic TUI tests live under `extensions/adapters/presenters/tui/tests/` and stub `termbox2` via `fen.testing.tui`.
Use them for viewport logic, input/key state, render rows, cache invalidation, and regressions; they must not open a real terminal.

For whole-frame assertions, install the capture stub:

```fennel
(install-termbox-stub! {:capture? true :cols N :rows N})
```

Render with `paint.paint-frame!` and assert with `screen-lines` or `presented-screen-lines`.
Reserve `make test-pty` for opt-in real-PTY integration/perf smoke.

## Rules

- Do not hand-edit or check in generated `dist/` trees.
- Keep Make targets usable without Nix unless the target name says `nix`.
- Keep `nix build .#fen` as the production binary path.
- Project extensions live in `.fen/extensions`; user-global extensions live in `${XDG_CONFIG_HOME:-~/.config}/fen/extensions`.
- Update embedded first-party extension manifests and reload/module lists when needed.
- Preserve hot reload: split state from behavior and avoid captured stale function references.
- Keep long work cooperative by passing `yield!` / `?yield-fn` through network, subprocess, reload/discovery, and large scans.

## Architecture

Before structural work, read `CLAUDE.md` core parsimony and `docs/architecture.md#design-principles`.
While `core-parsimony` is open, prefer existing events/register mechanisms, promote helpers to `fen.util.*` on second use, keep policy/data out of `packages/core`, and keep `main.fnl` CLI-entry only.

After module moves, run:

```sh
make graphs
sed -n '1,220p' docs/generated/graphs/summary.md
```
