# Development workflow

This page is the maintainer reference for day-to-day fen development, hot reload, local checks, and disposable build artifacts.

## Workflow

Normal development uses one single-file `fen` binary plus source overlays. No
generated Lua tree is needed for `.fnl` edits:

```sh
make dev-nix                        # nix build .#fen, then scripts/dev/fen-dev
make dev-portable                   # make fen, then scripts/dev/fen-dev with build/fen
# or, if FEN_BIN is set / fen is on PATH:
make dev
# edit .fnl, then /reload in the running TUI
```

`scripts/dev/fen-dev` sets `FEN_DEV_PATH` for package source roots and
`FEN_EXTENSION_ROOT` for `extensions/`, so `/reload` sees checkout source.

Fast checks while editing:

```sh
fennel scripts/test/fennel-check.fnl
make test                           # full Busted suite
make test TESTS=path/to/test.fnl    # focused test run
make smoke-mock                     # deterministic local provider/tool smoke
make check                          # fennel-check + doc validation + tests
```

TUI behavior has two complementary test layers.
Fast Busted tests run in-process under `extensions/adapters/presenters/tui/tests/` and stub `termbox2` through `fen.testing.tui`.
Use these tests for transcript viewport logic, key/input state machines, rendering rows, cache invalidation, and deterministic regressions that can be asserted from state or returned rows.
They should run under normal `make test` and should not open a real terminal.
The opt-in real-PTY smoke layer runs under `make test-pty` and is reserved for terminal integration, resize behavior that needs a real PTY, redraw/performance metrics, and smoke artifacts.
It uses a test-only native PTY helper from `packages/testing/vendor/` and does not use libvirt or a VM.
The initial smoke records raw PTY output, an asciinema v2 `session.cast`, and `metrics.json` under `tmp/tui-pty/`.

### Reproducing TUI stalls

`make stall-check` (wrapper: `scripts/dev/stall-check.sh`) is an opt-in harness for
cooperative-yield stalls — the multi-hundred-ms gaps between coroutine yields that
freeze the TUI on slow hardware.
It drives the real streaming transport (`fen_http.so` cooperative mode), the real
SSE parser, and a per-event JSON decode against a localhost SSE stream, timing the
wall gap between yields (the same metric `warn-if-stalled!` reports).
`FEN_DEBUG_CHUNK_DELAY_MS` (read once by `fen_http.c`) sleeps that many ms per
drained chunk slice, so a desktop reproduces the BB10/ARM per-chunk cost; the
harness prints a min/max/avg/median gap histogram and fails if any single resume
exceeds `FEN_STALL_BUDGET_MS` (default 250).
Knobs: `FEN_DEBUG_CHUNK_DELAY_MS` (default 15), `FEN_STALL_BUDGET_MS`,
`FEN_STALL_BODY_KB`, and `FEN_STALL_NICE=1` to also wrap the run in `nice`/`taskset`.
`FEN_DEBUG_CHUNK_DELAY_MS` works against the live binary too: set it before launching
`fen` and lower `FEN_TUI_STALL_WARN_MS` to make on-device stalls reproducible and
loud in `fen.log`.

Use Nix for reproducible/binary validation:

```sh
nix build .#fen
nix flake check
```

`make smoke-mock` starts `scripts/smoke/mock-openai.fnl`, writes a temporary `models.json`, and drives `scripts/dev/fen-dev --print` through both OpenAI Chat Completions and Responses adapters.
The mock returns a `read` tool call for `README.md`, checks that Fen executes the real read tool, then returns `OK` on the second model call.
It also runs retry variants for both adapters: the mock returns one `HTTP 500` with `Retry-After: 0` for `*-retry` models, and the smoke fails unless the provider retries and still reaches `OK`.

Nix owns binary assembly; do not use generated `dist/` trees as a dev loop or
release artifact.

### Nix result symlinks

`nix build` creates `result` symlinks in the current directory that point into
`/nix/store`. `nix flake check` or multi-output builds may leave numbered links
such as `result-1`, `result-2`, etc.; cross-builds may use explicit names like
`result-armv7` when passed with `-o`. These are local build artifacts, not source
files. It is safe to remove the symlinks from the repo root:

```sh
rm -f result result-* result-armv7
```

This does not delete the underlying store paths; `nix store gc` cleans
unreferenced store paths later. To avoid creating links for one-off checks, use
`nix build .#fen --no-link` or pass an explicit temporary output path with `-o`.

`fennel scripts/docs/check-docs.fnl` validates inline `;; @doc` blocks.
Each documented id must resolve to an export or contract entry, summaries are required, keys/kinds are checked, and duplicate ids fail fast.
`make check` runs this before the Busted suite so generated documentation inputs stay well-formed.

`fennel scripts/docs/check-links.fnl` validates relative Markdown links between hand-written docs.
File targets must exist, and `.md#anchor` / same-file `#anchor` targets must resolve to a heading under GitHub's slug rules.
External links, `*.html` and `docs/generated/` site-only targets, and vendored docs are skipped; `make check` runs it alongside the `@doc` check.

`make graphs` regenerates the tracked DOT sources, their SVG renderings, and the graph summary under `docs/generated/graphs/`.
SVG files are intentionally generated locally rather than tracked in Git.

`fennel scripts/test/fennel-check.fnl` compiles every `.fnl` file with `--globals`
locked to standard Lua 5.4 globals (src/) or standard + busted BDD globals
(tests/).
It catches syntax errors, unbalanced delimiters, and unknown identifiers
(typos, missing `local` bindings) without executing any code. Run it after
editing Fennel sources — it's faster than a full build and catches problems
plain Fennel compilation can otherwise miss (bad globals become silent
assignments in compiled Lua).


## Hot reload is the development loop

`/reload` is *the* way to iterate on this codebase. Under the canonical
`.#fen` + `scripts/dev/fen-dev` workflow, edit a `.fnl`, type `/reload` from the
running TUI, and keep working on the same session — the embedded Fennel compiler
loads the changed source directly through `FEN_DEV_PATH` / `FEN_EXTENSION_ROOT`
(as set by `scripts/dev/fen-dev`; equivalent `--dev-path` / `--extension-root` launcher
flags remain available for ad hoc runs).
Agents do **not** need to rebuild before telling the user a source change is
ready to hot reload when the user is on `scripts/dev/fen-dev`.

Do not rebuild generated Lua before `/reload` when using `scripts/dev/fen-dev`.
Restarting loses the TUI transcript, termbox state, the open session file, and
any cached config — it should feel costly. New code is designed under the
constraint "this must work under reload."

### How it works

`packages/fen/src/fen/main.fnl` keeps a `RELOADABLE` list of module names. `/reload`
calls `manual-reload!` for each: clear `package.loaded[modname]`,
re-`require` (re-runs the module body), then **copy the new exports
onto the original module table in place**. A `(local foo (require
:fen.core.foo))` capture keeps the same table reference; the next `foo.bar`
call resolves through the mutated table and lands on the new function.
Module-table lookup is the contract that makes reload work.

### What reloads, what doesn't

Reloadable: every `fen.core.*` behavior module in the list (including
the loader-owned extension API factory and the registry/event leaf modules), provider
implementation modules under `fen.extensions.provider_*`, and `fen.util.*`
helpers. First-party extension modules are reloaded by the extension loader
from their manifests. Bodies re-run, exports get re-pointed.

Not reloadable, identity must persist across reload:

- **`fen.extensions.tui.state`** — termbox lifecycle (init flag, dimensions), the
  append-only transcript, scroll position, status counters, view
  toggles. Re-running the body would reset the live terminal.
- **`fen.core.extensions.state`** — the bus subscriber lists, registries
  (tools, commands, presenters, hooks), system-prompt fragments,
  loaded-extension manifests, and the active presenter ui-slot. Reloadable
  `fen.core.extensions.*` behavior modules read and write through this companion
  module, mirroring the `fen.extensions.tui.state` ↔ reloadable TUI behavior split. Editing api,
  dispatch, prompt, presenter, or loader logic reloads cleanly; subscriptions
  and contributions survive because they live in `fen.core.extensions.state`.
- `fen.main` — already on the stack.

### Rules for new code

- **Keep long-running work cooperative.** Anything that may touch the network,
  drain a subprocess, walk many files/modules, build docs, reload extensions, or
  otherwise take more than a quick frame should accept and call a `yield!` /
  `?yield-fn` callback between chunks. The TUI drives work from coroutines;
  yielding is what lets it repaint, process cancel/quit keys, and show progress
  instead of appearing frozen.
- **Default to RELOADABLE.** Add the module name to the list in
  `packages/fen/src/fen/main.fnl`. Most code is iteration-prone and benefits.
- **Split state from behavior** when callers outside the module hold
  references that must persist. `fen.extensions.tui.state` ↔ reloadable TUI behavior is the canonical
  example: state lives in a non-reloadable module, rendering code in a
  sibling that reloads against it.
- **Cross-module wiring resolves at call time, not capture time.** Use
  `module.fn` lookups (reload-safe), not `(local fn module.fn)` captured
  into long-lived state (pinned to the old function for the rest of the
  process).
- **Reload-side-effects must be idempotent.** Modules in RELOADABLE that
  register things (commands, tools, fragments, event handlers) clear
  their prior registrations before re-registering, or every reload
  doubles them. First-party command extensions do this through their injected
  extension API at the top of its body. The external-extension loader follows
  the same pattern per extension.

### Why this shapes the api

Anything exported from a non-reloadable module (`fen.extensions.tui.state`,
`fen.core.extensions.state`) is shape-stable — its layout is a contract that
callers depend on across reload. Keep those surfaces small; iteration-
prone logic does not belong there. Behavior that *consumes* that state
(`fen.core.extensions.*`, TUI behavior modules) goes in sibling modules that reload against
it, so the state is what's stable, the code is what's editable.

The design choices in the extension leaf modules (event bus on the state table,
owner-tagged contributions, `unregister-by-owner`, and the command registry's
lookup-and-pcall path) fall out of this split: subscriptions and registries live
in `fen.core.extensions.state`, registry/event behavior lives behind reloadable
module tables, and the loader-owned api factory lives in `fen.core.extensions.loader.api`.
The api factory wraps its method references in closures that
resolve through the registry/event module tables at call time, so an api
held past a reload picks up the new behavior rather than pinning the old.


