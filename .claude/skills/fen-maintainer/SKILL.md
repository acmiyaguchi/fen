---
name: fen-maintainer
description: Develop, test, and maintain the Fen repository.
user-invocable: true
---

# Fen Maintainer

Use this for maintainer work in the `fen` repo: changing Fennel source, launcher/dev workflows, docs, tests, extensions, or distribution plumbing.

## Core workflow

- Prefer source-checkout development through the single-file runtime:
  ```sh
  make dev        # uses FEN_BIN or fen on PATH
  make dev-nix    # builds .#fen, then runs scripts/dev/fen-dev
  ```
- `scripts/dev/fen-dev` sets:
  - `FEN_DEV_PATH` for `packages/{core,util,fen}/src`
  - `FEN_EXTENSION_ROOT` for `extensions/`
- After editing `.fnl` during an interactive run, use `/reload`; do not rebuild generated Lua just to test source edits.

## Checks

Run the smallest useful check first:

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=path/to/test.fnl        # focused test file(s) or directory
make test BUSTED_ARGS='--filter=foo'    # focused test name
make test
```

Busted runner affordances:

```sh
make test-list                          # list test names/tags without running
make test-shuffle REPEAT=3              # shake out order/state leakage
FEN_INCLUDE_SMOKE_TESTS=1 make test     # include opt-in tests/smoke/ suites
```

- `TESTS` selects files or directories; `BUSTED_ARGS` is shell-split for runner
  flags (`--filter`, `--name`, `--tags`, `--exclude-tags`, `--shuffle`,
  `--repeat`, `--list`). Keep paths in `TESTS`.
- Directory-focused runs (e.g. `TESTS=.../tests`) exclude `tests/smoke/` unless
  `FEN_INCLUDE_SMOKE_TESTS=1` is set or a smoke file is passed explicitly.

## TUI tests

TUI behavior has two layers:

- Fast in-process Busted tests under
  `extensions/adapters/presenters/tui/tests/` stub `termbox2` via
  `fen.testing.tui`. Use these for viewport logic, input/key state, render
  rows, cache invalidation, and deterministic regressions. They run under
  `make test` and must not open a real terminal.
- For whole-frame text assertions, install the capture-enabled stub:
  `(install-termbox-stub! {:capture? true :cols N :rows N})`, render via
  `paint.paint-frame!`, then assert with `screen-lines` /
  `presented-screen-lines`. This is the substrate for story fixtures and
  golden TUI snapshots.
- Reserve `make test-pty` for opt-in real-PTY integration/perf smoke.

Use Nix for reproducible/binary/distribution validation:

```sh
nix build .#fen
nix flake check
```

For live-provider smoke tests on any machine with a runnable binary:

```sh
FEN_BIN=/path/to/fen make smoke
```

## Rules

- Do not hand-edit or check in generated `dist/` trees.
- Keep Make targets usable without Nix unless the target name says `nix`.
- Keep `nix build .#fen` as the canonical production binary path.
- Project extensions live in `.fen/extensions`; user-global extensions live in `${XDG_CONFIG_HOME:-~/.config}/fen/extensions`.
- When adding first-party extensions, update the embedded manifest registry and reload/module lists as needed.
- Preserve hot-reload behavior: split persistent state from reloadable behavior and avoid capturing old function references in long-lived state.
- Keep long-running work cooperative: pass `yield!` / `?yield-fn` through network, subprocess, reload/discovery, and large scan paths so the TUI stays responsive.

## Architectural guardrails

- Before structural work, read "Core parsimony guardrails" in `CLAUDE.md` and the design principles in `docs/architecture.md`; the active cleanup backlog is `gh issue list --milestone core-parsimony` (sequencing in issue #197).
- One mechanism per job: extend the events bus / existing register kinds rather than adding new hooks, kinds, or queues; promote helpers to `fen.util.*` on second use; keep doc data and provider transport policy out of `packages/core`.
- After moving modules, run `make graphs` and check `docs/generated/graphs/summary.md` for new cycles or fan-in/fan-out hot spots (`fen.main` fan-out should trend down, not up).
