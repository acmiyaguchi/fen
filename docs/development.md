# Development workflow

This page is the maintainer reference for day-to-day fen development, hot reload, local checks, and disposable build artifacts.

## Workflow

Normal development uses one single-file `fen` binary plus source overlays. No
generated Lua tree is needed for `.fnl` edits:

```sh
make dev-nix                        # nix build .#fen, then scripts/fen-dev
# or, if FEN_BIN is set / fen is on PATH:
make dev
# edit .fnl, then /reload in the running TUI
```

`scripts/fen-dev` sets `FEN_DEV_PATH` for package source roots and
`FEN_EXTENSION_ROOT` for `extensions/`, so `/reload` sees checkout source.

Fast checks while editing:

```sh
fennel scripts/fennel-check.fnl
make test                           # full Busted suite
make test TESTS=path/to/test.fnl    # focused test run
make check                          # fennel-check + doc validation + tests
```

Use Nix for reproducible/binary validation:

```sh
nix build .#fen
nix flake check
```

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

`fennel scripts/check-docs.fnl` validates inline `;; @doc` blocks.
Each documented id must resolve to an export or contract entry, summaries are required, keys/kinds are checked, and duplicate ids fail fast.
`make check` runs this before the Busted suite so generated documentation inputs stay well-formed.

`fennel scripts/fennel-check.fnl` compiles every `.fnl` file with `--globals`
locked to standard Lua 5.4 globals (src/) or standard + busted BDD globals
(tests/).
It catches syntax errors, unbalanced delimiters, and unknown identifiers
(typos, missing `local` bindings) without executing any code. Run it after
editing Fennel sources — it's faster than a full build and catches problems
plain Fennel compilation can otherwise miss (bad globals become silent
assignments in compiled Lua).


## Hot reload is the development loop

`/reload` is *the* way to iterate on this codebase. Under the canonical
`.#fen` + `scripts/fen-dev` workflow, edit a `.fnl`, type `/reload` from the
running TUI, and keep working on the same session — the embedded Fennel compiler
loads the changed source directly through `FEN_DEV_PATH` / `FEN_EXTENSION_ROOT`
(as set by `scripts/fen-dev`; equivalent `--dev-path` / `--extension-root` launcher
flags remain available for ad hoc runs).
Agents do **not** need to rebuild before telling the user a source change is
ready to hot reload when the user is on `scripts/fen-dev`.

Do not rebuild generated Lua before `/reload` when using `scripts/fen-dev`.
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
  doubles them. `extensions.builtin_commands` does this through its injected
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


