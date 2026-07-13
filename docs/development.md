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
make test TESTS=path/to/test.fnl    # focused test-file run
make test BUSTED_ARGS='--filter=foo' # focused test-name run
make test-list                      # inspect Busted names/tags without running
make test-shuffle REPEAT=3          # shake out order/state leakage
make smoke-mock                     # deterministic local provider/tool smoke
make check                          # fennel-check + doc validation + tests
```

`TESTS` selects files or directories passed to Busted.
`BUSTED_ARGS` is passed through to Busted for runner-level affordances such as `--filter`, `--name`, `--tags`, `--exclude-tags`, `--shuffle`, `--repeat`, and `--list`.
Keep paths in `TESTS`; `BUSTED_ARGS` is intentionally shell-split for ordinary option flags.
Directory-focused `TESTS=.../tests` runs keep `tests/smoke/` excluded unless `FEN_INCLUDE_SMOKE_TESTS=1` is set or a smoke file is passed explicitly.

TUI behavior has two complementary test layers.
Fast Busted tests run in-process under `extensions/adapters/presenters/tui/tests/` and stub `termbox2` through `fen.testing.tui`.
Use these tests for transcript viewport logic, key/input state machines, rendering rows, cache invalidation, and deterministic regressions that can be asserted from state, returned rows, or a capture-enabled virtual screen.
Pass `{:capture? true :cols N :rows N}` to `fen.testing.tui.install-termbox-stub!` when a test needs whole-frame text assertions; `screen-lines` returns normalized back-buffer rows and `presented-screen-lines` returns the last presented frame.
That capture path is the substrate for story-style fixtures and future golden TUI snapshots.
Fast tests should run under normal `make test` and should not open a real terminal.
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

### Statistical profiling

The opt-in first-party profiler records bounded Lua VM instruction samples and exports flame-graph artifacts without adding a metrics framework or profiler lifecycle to core.
It is intended for development captures of TUI interaction, agent turns, tools, and `/reload`.

#### Quick start

Start a function-level capture, perform the operation under investigation, then save it:

```text
/profile start --period 50000 --mode functions
/reload
/profile save tmp/profiles/reload
```

`save` stops an active capture before serialization so the exporter cannot mutate or profile its own input.
Open `tmp/profiles/reload/profile.speedscope.json` in [Speedscope](https://www.speedscope.app/), or pass `profile.folded` to classic FlameGraph tooling.

When no output directory is supplied, `/profile save` chooses a unique timestamped directory under `${XDG_STATE_HOME:-~/.local/state}/fen/profiles/`.
An explicitly supplied directory is used as given and its three profile files may replace files from an earlier capture.

#### Command reference

| command | effect |
| --- | --- |
| `/profile start` | Reset prior samples and start function-level sampling with a 25,000-instruction period. |
| `/profile start --period N` | Set the count-hook period; larger values reduce overhead and sampling detail. `N` must be an integer of at least 100. |
| `/profile start --mode functions\|lines` | Select function frames or include the current source line in frame identity. |
| `/profile status` | Report running state, configuration, sample/drop counts, frame/stack counts, and measured process CPU duration. |
| `/profile stop` | Stop sampling while retaining the capture for reporting or export. |
| `/profile report` | Print the status summary plus the native/blocking-time limitation. |
| `/profile save [directory]` | Stop if needed and write the three artifacts below. |
| `/profile reset` | Stop and discard the in-memory capture. |
| `/profile help` | Print compact command usage. |

Starting a new capture stops and replaces an existing capture.
The profiler refuses to replace an unrelated active Lua debug hook.
Function mode is the lower-overhead default.
Line mode can create many more distinct frames and is best reserved for short, focused captures.
On slow ARM systems, start around `--period 100000` and lower the period only when more detail is needed.

#### Artifacts

A save writes:

- `profile.speedscope.json` — an interactive sampled flame graph with zero-based shared frame indexes;
- `profile.folded` — root-to-leaf folded stacks with integer sample weights;
- `profile.json` — capture configuration, limits, sample/drop counts, thread labels, process CPU duration, and explicit interpretation limits.

Capture storage is bounded by frame, stack, depth, and retained-thread limits.
A sample that cannot be represented without exceeding a frame, stack, or depth limit is dropped rather than exported with false ancestry.
`/profile status` and `profile.json` report dropped samples.

#### Interpreting a capture

The sampler uses Lua 5.4's instruction-count `debug.sethook` facility.
A wider frame means that the function appeared in more **Lua VM instruction samples**; the width is not elapsed milliseconds.
`profile.json` labels the sample kind and unit so downstream analysis does not accidentally present instruction counts as time.

Blocking native/C work generates no count-hook samples, including time inside libcurl, TLS, termbox presentation, subprocess waits, and filesystem calls.
Use the TUI's `tui-stall` diagnostics and `make stall-check` alongside a statistical capture when investigating responsiveness.
Native host profilers such as `perf` remain complementary when attribution inside C libraries or the kernel is required.

Fen explicitly propagates the profiler hook through its cooperative coroutine constructors, so turns, reloads, compaction/handoff work, and parallel tool tasks created during a capture remain visible.
Ordinary debugger or coverage hooks are not propagated, and coroutines created directly through Lua's `coroutine.create` retain Lua's default thread-local hook behavior.
The profiler state and active hook survive `/reload`; reloadable command/export behavior is kept separate from that persistent state.

#### Agent access

The current interface is intentionally human-controlled through `/profile`.
The full quick workflow, commands, artifacts, interpretation, and limitations are discoverable at runtime with `/docs search profile`, `fen_docs {topic: "search", query: "profile"}`, or `fen_docs {topic: "introspectors", name: "capture"}`.
The same workflow is embedded in the profiler capture snapshot and exported `profile.json`, so the model can retrieve it through `agent_state` without relying on repository Markdown.
No profiler tool is advertised, and the model cannot start, stop, reset, or save a capture itself.
Agent-controlled profiling and startup environment configuration remain follow-up work under issue #305.

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

Busted source-checkout runs install a generated-Lua cache for Fennel modules so
`--auto-insulate` can keep resetting `package.loaded` between test files without
recompiling the same unchanged dependency closure every time.
Set `FEN_TEST_COMPILE_CACHE=0` to disable it, `FEN_TEST_COMPILE_CACHE_DIR` to
choose the cache directory, and `FEN_TEST_COMPILE_CACHE_STATS` to write simple
hit/miss counters for benchmarking.
The cache stores compiled Lua only; each module chunk still executes in the
current test VM so test isolation and module registration side effects are
unchanged.
Sources containing `import-macros` or `require-macros` bypass the cache because
Fennel permits dynamic and transitive macro dependencies that cannot be safely
fingerprinted from source text alone.
Unknown compiler options and option values that cannot be serialized
canonically also bypass caching rather than risk reusing incompatible Lua.


## Contributing changes

By default, land work through a pull request, not a direct push to `main`.

- Branch: `git checkout -b <type>/<slug>` (e.g. `refactor/...`, `perf/...`, `chore/...`).
- Commit focused changes; run focused tests locally while iterating.
- Open a PR: `gh pr create --base main`.
- The `pr` workflow runs the cheap native gate on the PR before merge:
  `fennelCheck` plus the Busted test suite.
- Run `make check` locally when practical, especially before merging behavior changes;
  full cross-target release validation stays on tagged releases.
- Copilot code review runs on the PR, applying the repo review rules in
  `.github/copilot-instructions.md` and the path-scoped
  `.github/instructions/*.instructions.md`; address or acknowledge its comments
  before merging.
- Merge with `gh pr merge <N> --squash --delete-branch`.

Copilot review only fires on pull requests, so a direct push to `main` ships
unreviewed — prefer a PR even for small changes unless the user explicitly opts
in to a direct push.
`gh` resolves against the current repo, so run these from inside the `fen` checkout.

### Direct push to `main` (explicit opt-in only)

Direct pushes to `main` are allowed **only when the user explicitly asks for
one** (e.g. "push directly to main"). Absent an explicit request, always use a
PR — never infer a direct push from silence, urgency, or a change looking small.

When the user does opt in explicitly:

- Run `make check` locally first — a direct push skips pre-merge PR gating and Copilot review.
  The `pr` workflow also runs after pushes to `main`, but that is post-landing validation, not a substitute for a local check.
- Push with `git push origin main`.
- Call out in your reply that the change shipped by direct push without PR review.

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

`fen.core.extensions.loader.reload` owns in-process reload. The core module
set is derived from `package.loaded` — every loaded `fen.*` module except
`fen.extensions.*` (extension modules reload through their manifest's
`reload-modules`) and the persistent-identity modules (`fen.main`,
`fen.core.extensions.state`) — so there is no hand-kept list to maintain.
`/reload` fingerprints the active sources and skips core recompilation when
none changed.
When any core source changed, it clears and re-`require`s the complete reloadable
core set so consumers that captured dependency functions are refreshed safely.
Use `/reload --all` to force that reload even when all fingerprints are unchanged.
After a successful require, reload **copies the new exports onto the original
module table in place** and commits the new fingerprint; a compile failure keeps
the last successful fingerprint so the next `/reload` retries it.
A `(local foo (require :fen.core.foo))` capture keeps the same table reference;
the next `foo.bar` call resolves through the mutated table and lands on the new
function.
Module-table lookup remains the preferred hot-reload contract.

### What reloads, what doesn't

Reloadable: every loaded `fen.core.*`, `fen.util.*`, and CLI-side `fen.*`
behavior module — picked up automatically from `package.loaded`.
Extension modules (including the provider adapters and the JSONL session
backend) are reloaded by the extension loader from their manifests'
`reload-modules`. Bodies re-run, exports get re-pointed.

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
- **Default to reloadable.** Core/util `fen.*` modules are picked up
  automatically from `package.loaded`; extension modules list themselves in
  their manifest's `reload-modules`. Only persistent-identity modules opt out
  (the `NON-RELOADABLE` set in `fen.core.extensions.loader.reload`).
- **Split state from behavior** when callers outside the module hold
  references that must persist. `fen.extensions.tui.state` ↔ reloadable TUI behavior is the canonical
  example: state lives in a non-reloadable module, rendering code in a
  sibling that reloads against it.
- **Cross-module wiring resolves at call time, not capture time.** Use
  `module.fn` lookups (reload-safe), not `(local fn module.fn)` captured
  into long-lived state (pinned to the old function for the rest of the
  process).
- **Reload-side-effects must be idempotent.** Reloadable modules that
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


