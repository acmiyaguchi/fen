# Extensions

fen has a small Lua/Fennel extension system for adding behavior around
the core agent loop without patching `packages/core/` directly. Extensions
can add slash commands, tools, hooks, system-prompt fragments, event
subscribers, and presenters.

The extension system is intentionally a **soft plugin boundary**: extensions run
inside the same Lua VM as the agent and have normal host access. Install only
extensions you trust.

## Mental model

There are three pieces:

| piece | path | role |
| --- | --- | --- |
| Extension API / registries | `packages/core/src/fen/core/extensions/` | Event bus, command/tool/presenter registries, UI slot, lifecycle dispatch |
| Extension loader | `packages/core/src/fen/core/extensions/loader/` | Walks roots for extension entries, checks deps, loads/reloads each spec |
| Extension source | `extensions/adapters/**` and `extensions/behaviors/**` (first-party) or user config dirs | Contributes behavior by calling the API |

An extension is usually a directory with an entry and an optional manifest:

```text
my-extension/
  manifest.fnl   # optional metadata for the loader
  init.fnl       # runtime registration entrypoint (default; manifest can override)
```

Short version:

```text
manifest.fnl = how to load/reload/describe the extension (optional)
init.fnl     = what the extension actually does once loaded
```

The `fen.extensions.*` namespace is a convention for first-party rocks, not a
structural requirement. Third-party extensions may pick any namespace, and
project-local drop-ins need no namespace at all — the manifest or local entry
file decides.

First-party source is organized by role, not by register kind:

```text
extensions/
  adapters/     # providers, presenters, session storage backends
  behaviors/    # commands, tools, prompt fragments, panels, controls, hooks
```

Within `behaviors/`, `actions/` contains command-oriented workflows such as conversation/session lifecycle commands.
These are not session adapters: the adapter is the storage backend under `adapters/session-backends/`, while `behaviors/actions/sessions/` is the frontend behavior that calls whichever backend is active.

Adapters connect fen to a substrate or backend.
Behaviors add agent/user-facing capabilities and may register any mix of commands, panels, tools, status items, prompt fragments, controls, and hooks.
For example, `behaviors/inspectors/queue` owns `/queue`, `/cancel-all`, panel rendering, and persistent panel state as one cohesive behavior; the queue data itself lives in the [steering queue service](#steering-queue-service) it renders.

## Discovery

Extensions are discovered by walking known roots for extension directories and single-file entries.
Internal first-party extensions are loaded from the embedded manifest registry.
First-party overlay roots are walked recursively so the in-repo adapter/behavior taxonomy can be used during source-checkout development.
Project and user drop-in roots remain shallow and flat.

Roots, in priority order (first match wins per name):

1. Explicit `--extension <path>` flags — single extension dir or single file
2. Trusted first-party flat overlays — `--extension-root` /
   `FEN_EXTENSION_ROOT`, used by the single-file launcher for source-checkout
   first-party extension development
3. Project-local drop-ins — `.fen/extensions/` in the current directory and
   each ancestor up to the first `.git`/`.hg` worktree marker (or filesystem
   root if no marker exists)
4. User config drop-ins — `$FEN_EXTENSIONS_PATH` (colon-separated explicit
   roots) and `${XDG_CONFIG_HOME:-~/.config}/fen/extensions/`
5. Internal first-party extensions — known embedded manifest modules from the
   runtime ZIP/module searchers

Project-local `fen/extensions/` is intentionally not an implicit filesystem
root. Use `.fen/extensions/` for project drop-ins,
`${XDG_CONFIG_HOME:-~/.config}/fen/extensions/` for user-global drop-ins, or
name another root explicitly.

For project and user drop-ins, discovery is shallow: only direct children of a root are considered.
A candidate may be either:

- a directory containing `manifest.{fnl,lua}` or `init.{fnl,lua}` (the typical shape)
- a single file `foo.fnl`/`foo.lua` — the file is the entry and the extension
  name comes from the basename

Project-local extensions are enabled by default even without
`:enabled-by-default true`, because placing an extension under a project's own
`.fen/extensions/` is treated as intent to run it. User-global discovered
extensions still honor `:enabled-by-default`; explicit `--extension <path>`
always loads regardless of that field.

In the canonical source-checkout workflow, `scripts/dev/fen-dev` prepends `extensions`
to `FEN_EXTENSION_ROOT` for the single-file runtime. First-party flat
extensions are loaded directly from `.fnl` source under the taxonomy directories;
no rebuild or `dist/` mirror is required for reload-driven development.

Hidden and underscored entries in project-local roots are skipped silently:

```text
.foo/       # skipped
_foo/       # skipped
.foo.fnl    # skipped
_foo.lua    # skipped
foo/        # considered
foo.fnl     # considered
```

If both `foo/` and `foo.fnl`/`foo.lua` exist in the same root, the directory
wins. Duplicate names across roots are first-seen-wins; later duplicates are
skipped silently.

## Manifest

Directory extensions may declare a `manifest.fnl` (or `manifest.lua`) at their
root. A Fennel manifest is just a table:

```fennel
{:name :hello
 :description "Example extension"
 :enabled-by-default true
 :entry-module :fen.extensions.hello
 :requires {:lua [:lfs]
            :bin ["git"]}
 :reload-modules [:fen.extensions.hello.helper
                  :fen.extensions.hello]
 :reload-exclude [:fen.extensions.hello.state]}
```

Fields:

| field | meaning |
| --- | --- |
| `:name` | Extension owner/name used for introspection and teardown. Falls back to dir name. |
| `:description` | Human-readable description. |
| `:enabled-by-default` | Whether discovered extensions load automatically. Explicit `--extension` always loads. |
| `:entry-module` | Lua module name resolved through `require`. The module should return a register function, or a table with `:register`. Used by rock-shaped installs and compatibility packaging. |
| `:entry` | File path relative to the manifest dir. The file is `dofile`'d and should return a register function, or a table with `:register`. Used by path-shaped (project drop-ins, single-file). |
| `:requires.lua` | Lua modules that must be require-able before enabling. |
| `:requires.bin` | Binaries that must exist on `PATH` before enabling. |
| `:reload-modules` | Module names to clear from `package.loaded` on reload. |
| `:reload-exclude` | Module names to preserve even if listed or otherwise known. Use for persistent state. |

If no manifest is present, the loader uses the directory basename as the
extension name and falls back to `<dir>/init.{fnl,lua}`. If a manifest is
present but neither `:entry-module` nor `:entry` is set, the same `init` fallback
is used.

The loader records disabled, missing-dependency, loaded, and error states for
`/extensions` and `api.list :extensions`.

Discovery and reload code may receive an optional cooperative yield callback from the presenter runtime.
Long filesystem walks, manifest scans, and subprocess drains should call it between chunks or directory entries.
The callback may raise for cancellation, so discovery helpers must close pipes and files before rethrowing.

## Entrypoint shape

One entrypoint shape is preferred: the loaded entry returns a register function that receives `api`.
A manifest can point at either a file (`:entry`) or a module (`:entry-module`); without a manifest, the `init.{fnl,lua}` file fallback is used.
The loader creates the API, removes prior owner-tagged contributions, and invokes the register function, so normal extensions do not need to call `unregister-by-owner` themselves:

```fennel
(fn [api]
  (api.register :command
                {:name :hello
                 :description "Say hello"
                 :handler (fn [_args _ctx]
                            (api.emit {:type :info :text "hello"}))}))
```

A table with `:register` is also honored and is useful when a module wants to expose helpers for tests:

```fennel
{:register
 (fn [api]
   (api.register :command
                 {:name :hello
                  :handler (fn [_args _ctx]
                             (api.emit {:type :info :text "hello"}))}))}
```

Lua extensions work too:

```lua
return function(api)
  api.register("command", {
    name = "hello",
    description = "Say hello",
    handler = function(args, ctx)
      api.emit({ type = "info", text = "hello" })
    end,
  })
end
```

File-backed extensions can load sibling files via `(api.load :state)` —
resolved relative to the manifest dir, no namespace required:

```fennel
(fn [api]
  (let [state (api.load :state)]   ; loads ./state.fnl or ./state.lua
    (api.register :command
                  {:name :hello :handler (fn [] (state.greet))})))
```

Legacy module-shaped entries that self-register from the module body are still tolerated for compatibility, but new extensions should not construct an api directly.
Treat API construction as loader-owned.

## API surface

The API table passed to an extension contains:

| method / field | purpose |
| --- | --- |
| `api.register(kind, spec)` | Register public contribution kinds: tools, commands, controls, hooks, status items, or panels. |
| `api.on(event-name, handler)` | Subscribe to event bus events. `:*` receives all events. |
| `api.emit(event-table)` | Publish an event. |
| `api.prompt(text-or-fn, opts)` | Add system-prompt fragments. |
| `api.list(kind)` | Frozen introspection lists. |
| `api.introspect` | Introspection helpers: `collect`. |
| `api.commands` | Command helpers: `dispatch`. |
| `api.turn` | Turn helpers: `submit!`. |
| `api.auth` | Auth backend helpers: `find-backend`. |
| `api.session` | Active session helpers: `active-backend`, `set-info!`, `info`. |
| `api.diagnostics` | Diagnostic helpers: `list-errors`, `error-log-path`. |
| `api.settings` | Settings proxy: `load!`, `set-defaults!`, `set-thinking-default!`. |
| `api.models` | Model registry proxy: `list`, `resolve`, `canonical-id`. |
| `api.ui` | Active presenter UI slot helpers: `has-ui?`, `notify`, `prompt`, `select`. See [UI helper fallback behavior](#ui-helper-fallback-behavior). |
| `api.load(name)` | File-backed extensions only: load `<manifest-dir>/<name>.{fnl,lua}` and return its value. Use for sibling files without a namespace. |

For third-party extensions, this API table is the compatibility contract. Raw
`fen.core.*` requires are private implementation details unless explicitly
surfaced above. First-party in-tree extensions may still require internals when
there is no public equivalent, but should prefer `api` as the boundary.

`api.register` has a public and privileged kind split.
Public extensions may register `:command`, `:tool`, `:hook`, `:input-handler`, `:status`, `:panel`, `:control`, and `:introspect`.
Infrastructure kinds `:provider`, `:auth-backend`, `:session-backend`, and `:presenter` are reserved for embedded first-party extensions until fen has an explicit third-party trust/capability model.

### Capability taxonomy

The table above lists every method; this groups them by what they do and which tier sees them today.
Capability category — not namespace — is the natural axis for any future public/privileged split: contribution and read-only introspection are safe for any extension, while mutation and infrastructure install are tier-sensitive.

| capability | methods | tier today |
| --- | --- | --- |
| Contribute | `register` (7 public kinds), `prompt`, `on`/`emit` | base |
| Contribute (infrastructure) | `register` (`:provider`, `:auth-backend`, `:session-backend`, `:presenter`) | privileged (first-party) |
| Introspect (read-only) | `list` (14 kinds), `introspect.collect`, `models.*`, `diagnostics.*`, `session.info`/`active-backend`, `auth.find-backend` | base |
| Mutate | `settings.set-defaults!`, `settings.set-thinking-default!`, `session.set-info!` | base |
| Drive | `turn.submit!`, `commands.dispatch` | base |
| UI | `ui.has-ui?`/`notify`/`prompt`/`select` | base |

The surface is 14 namespaces and 23 leaf methods, with `register` fanning out to 12 contribution kinds and `list` to 15 introspection kinds.
Only the four infrastructure register kinds are tier-gated today; the `Mutate` methods are currently exposed to every extension regardless of source.

### Registering commands

```fennel
(api.register :command
              {:name :hello
               :description "Say hello"
               :idle-only? false
               :handler (fn [args ctx]
                          (api.emit {:type :assistant-text
                                     :text (.. "hello " args)}))})
```

Command handlers receive:

- `args` — text after the command name
- `ctx` — the interactive run state used by built-ins

#### Argument completion

A command may add an optional `:complete` function to supply argument completions to the TUI's inline completion menu.
The menu filters as you type and opens above the input while editing a `/command`:

```fennel
(api.register :command
              {:name :skills
               :handler (fn [args ctx] ...)
               :complete (fn [arg-prefix ctx]
                           [{:label "redact-logs" :value "redact-logs"
                             :description "Redact sensitive strings"}])})
```

`:complete` receives the current argument word (`arg-prefix`) and the run context.
It returns a list of choices shaped `{:label str :value any :description str?}` — the same shape `api.ui.select` consumes.
`:value` is the token spliced into the input on commit.
`:label` and `:description` are shown in the menu.
The menu filters the returned choices by the typed word, so a completer may return its full candidate set.
Errors in `:complete` are isolated and never crash input.
Return `[]` or nothing for "no completions".

Commands that need to start a normal agent turn should use the small turn helper instead of mutating `ctx.turn` or `ctx.busy?` directly:

```fennel
(let [result (api.turn.submit! ctx "Execute the approved plan now." {:when-busy :reject})]
  (when (not result.ok)
    (api.emit {:type :error :error result.error})))
```

`api.turn.submit!` accepts the command context, the user text to submit, and optional busy/display behavior.
Calls through this API echo the submitted user text to the live transcript by default.
Pass `{:emit-user? false}` to suppress that when an extension has already displayed equivalent text.

- `{:when-busy :reject}` — return `{:ok false :error "agent is busy"}` when a turn is active.
- `{:when-busy :steering}` — queue the text as steering for the active turn and return `{:ok true :queued true :queue :steering}`.
- `{:when-busy :follow-up}` — queue the text as a follow-up for the active turn and return `{:ok true :queued true :queue :follow-up}`.

When idle, it starts the same normal user-turn path used by presenter input and returns `{:ok true :started true}`.
Empty text returns `{:ok false :error "cannot submit an empty user turn"}`.
Unknown `:when-busy` modes return `{:ok false :error "invalid when-busy mode: ..."}`.

### Registering tools

Tool specs match the built-in `AgentTool` shape handled by
`packages/core/src/fen/core/tools.fnl`:

```fennel
(api.register :tool
              {:name :greet
               :label "greet"
               :description "Greet someone"
               :parameters {:type :object
                            :properties {:name {:type :string}}
                            :required [:name]}
               :execute (fn [args _ctx]
                          {:content [{:type :text
                                      :text (.. "hello " args.name)}]})})
```

### Hooks

v1 exposes a before-tool hook:

```fennel
(api.register :hook
              {:before-tool
               (fn [tool-name args ctx]
                 (when (and (= tool-name :bash)
                            (string.find (or args.cmd "") "rm %-rf"))
                   {:block true :reason "dangerous command"}))})
```

If a hook returns `{:block true :reason "..."}`, the tool call is blocked.

### System prompt fragments

Prefer the ergonomic `api.prompt` helper:

```fennel
(api.prompt
  "Extra instruction from my extension."
  {:id :my-extra-instruction
   :title "My extra instruction"
   :description "Short inspection text"
   :order 90})
```

Fragments are sorted by numeric `:order` and registration sequence, then joined
with blank lines. The first argument to `api.prompt` may also be a function
evaluated with the prompt render context when the system prompt is built.
Failures degrade to an HTML comment instead of crashing prompt assembly.

### Event bus

Subscribe to one event:

```fennel
(api.on :tool-call
        (fn [ev]
          (api.emit {:type :info
                     :text (.. "tool: " (tostring ev.name))})))
```

Subscribe to all events:

```fennel
(api.on :* (fn [ev] ...))
```

Handlers are `pcall` isolated so one failing extension does not stop sibling
handlers.

Common event types include:

- `:agent-started`, `:agent-turn-complete`, `:agent-shutdown`
- `:llm-start`, `:llm-end`
- `:tool-call`, `:tool-result`
- `:assistant-text`, `:assistant-thinking`
- `:assistant-text-delta`, `:assistant-thinking-delta`, `:assistant-stream-end`
- `:user`, `:info`, `:queued`, `:error`, `:cancelled`
- `:extension-loaded`
- presenter-control events such as `:reset-conversation`, `:redraw`,
  `:set-status-info`
- `:agent-turn-complete` fires once after a submitted user turn is fully done,
  including tool loops, queued follow-up/steering consumed by that step,
  cancellation cleanup, and the presenter returning to idle.
  Its `:status` is `:ok`, `:cancelled`, or `:error`.
- `:dismiss` — emitted by the TUI on `Esc`; extensions owning a togglable
  panel should subscribe and close it (no-op when not displayed)

Custom event types should be namespaced by convention, e.g.
`:git-checkpoint/snapshot-created`.

### Registering introspection snapshots

An `:introspect` contribution exposes a sanitized, read-only snapshot of extension-owned state.
Snapshots are collected on demand by `agent_state`, `/extensions <name>`, and future runtime diagnostics.

```fennel
(api.register :introspect
              {:name :panel
               :description "Current panel state"
               :snapshot (fn [_ctx]
                           {:visible? state.visible?
                            :selected-name state.selected-name})})
```

Names are owner-scoped: two extensions may both register `:summary`.
Use `api.list :introspectors` to inspect descriptors without executing snapshot thunks.
Use `api.introspect.collect` to collect owner-scoped outputs:

```fennel
(api.introspect.collect)         ; all owners
(api.introspect.collect :my-ext) ; one owner
```

Snapshots must be cheap, side-effect-free, non-blocking, and must not expose secrets.
Return plain JSON-friendly data: strings, numbers, booleans, nil, arrays, and tables.
Avoid functions, userdata, threads, and cycles.
Snapshot failures are isolated and surface as `{:error "..."}` without preventing other snapshots from being collected.
For hot reload, snapshot thunks should resolve behavior and persistent state at call time rather than capturing stale function locals.

### Presenters

A presenter is an interactive host such as the built-in TUI, a future REPL, or
an RPC server. Only one active presenter owns the UI slot.

```fennel
(api.register :presenter
              {:name :my-presenter
               :active? true
               :init (fn [ctx] ...)
               :run (fn [ctx] ...)
               :shutdown (fn [ctx] ...)
               :ui {:notify (fn [text opts] ...)
                    :prompt (fn [opts] ...)
                    :select (fn [opts] ...)}})
```

`main.fnl` calls presenter lifecycle through `core.extensions`:

```text
init-active-presenter → run-active-presenter → shutdown-active-presenter
```

The built-in TUI is a first-party extension under `extensions/adapters/presenters/tui/`.
For how its regions, status items, panels, and controls fit together, see the [TUI design guide](tui.md).

#### `api.ui` public surface

`api.ui` is the only extension-facing UI namespace; it is not going away or flattening to top-level `api.select`/`api.notify` helpers.
Its intended public surface is exactly four methods:

- `api.ui.has-ui?()` — true when a presenter is active and owns the UI slot.
- `api.ui.notify(text, opts)` — show a message through the active presenter.
- `api.ui.prompt(opts)` — ask the active presenter for free-text input.
- `api.ui.select(opts)` — ask the active presenter to pick from `opts.choices`; `opts.initial-query` optionally supplies the selector's initial search text.

Selector choices have the shape `{:label str :value any :description str?}`.
Search-capable presenters initialize their filtering and ranking from `opts.initial-query`, while presenters without interactive filtering may ignore it.

Everything inside `fen.core.extensions.register.presenter` beyond `build-ui-slot` (slot promotion, presenter registration/lookup, lifecycle dispatch) is core runtime plumbing, not part of this contract, and may change without notice.

#### UI helper fallback behavior

`api.ui` methods dispatch to the active presenter's `:ui` table when one is registered.
When no presenter is active, each method falls back to explicit, non-blocking behavior instead of touching stdin:

- `notify` writes the message to stderr as a plain line.
- `prompt` and `select` log a one-line warning to stderr and return `nil`.

Extensions that need interactive input should call `api.ui.has-ui?()` first and treat a `nil` result from `prompt`/`select` as "no UI available" rather than "the user answered nothing."

### Registering status items

A `:status` is one block in the presenter's status bar, in the
Waybar/Polybar style: each item renders independently and the
presenter composes them. First-party status items in the TUI surface
the model name, context tokens, queue counts, and scroll offset.

```fennel
(api.register :status
              {:name :git-branch
               :side :right
               :order 10
               :render (fn [_ctx]
                         {:text (current-branch) :style :dim})})
```

| field | meaning |
| --- | --- |
| `:name` | Identifier (required). Owner-scoped; two extensions may share a name. |
| `:render` | `(fn [ctx] {:text str :style style-keyword})` (required). Return `nil` to hide for this frame. |
| `:side` | `:left` or `:right`. Defaults to `:left`. |
| `:order` | Number; lower = closer to the side anchor. Defaults to `50`. |

Sort is ascending by `:order`, then owner, then name. The right group
is right-aligned; the left group is left-aligned. `:render` is invoked
every frame and must be cheap and side-effect-free.

### Registering panels

A `:panel` is a bounded vertical region above the input or below the
status bar. It owns a row count per frame and a list of rows to paint;
the presenter handles geometry, clipping, and clamping to available
space. The TUI's busy spinner is the smallest first-party example
(`extensions/adapters/presenters/tui/panels/busy.fnl`).

```fennel
(api.register :panel
              {:name :recent-commits
               :placement :above-input
               :order 20
               :height (fn [_ctx] 3)
               :render (fn [_ctx]
                         [{:text (.. "HEAD: " (head-summary)) :style :dim}
                          {:text (.. "+ "    (changed-files)) :style :dim}
                          {:text "" :style :dim}])})
```

| field | meaning |
| --- | --- |
| `:name` | Identifier (required). |
| `:height` | `(fn [ctx] <int>)` (required). Non-negative; `0` hides the panel for this frame. |
| `:render` | `(fn [ctx] [<row>...])` (required). Each row is `{:text str ?:style style-keyword ?:segments [...]}`. An empty list is equivalent to height `0`. |
| `:placement` | `:below-status` or `:above-input`. Defaults to `:above-input`. |
| `:order` | Number; lower = closer to the placement anchor. Defaults to `50`. |

`:below-status` panels stack downward from the status row; lower
`:order` is closer to the top. `:above-input` panels stack upward
from the input row; lower `:order` is closer to the input. The
presenter walks panels per-frame inside `pcall`, so one extension's
render error becomes a single `panel-error:<name>` row instead of
crashing the frame.

`:render` and `:height` run on every frame. Keep both cheap; do
expensive work in cooperative event handlers and cache the result in extension
state.

### Semantic styles

`:status` items and `:panel` rows declare colors with semantic
keywords; presenters own the actual color tables.

| keyword | typical use |
| --- | --- |
| `:user` | User-authored content / accent |
| `:assistant` | Assistant content / section headings |
| `:tool` | Tool-call labels |
| `:error` | Errors |
| `:dim` | Secondary or muted text |
| `:status` | Default for status items (TUI: reverse-video bar fg) |

Unknown styles fall through to a presenter default; new styles will
be added as the theme system matures, so `:render` should not depend
on the exact rendering of any one keyword.

## Goal companion

The first-party `goal` extension (`extensions/behaviors/companions/goal/`) adds `/goal` for bounded autonomous objective execution.
It is the interactive MVP for the goal-orchestration roadmap: a user gives fen an objective, fen works through normal model turns, and the extension stops the run when the model reports completion/blockage/error or when the iteration cap is reached.
The MVP composes existing primitives instead of adding a second agent loop.
The submitted goal prompt tells the model to maintain `todo_write`, use `subagent` for self-contained scout/plan/review work when helpful, run appropriate checks, and end every iteration with an explicit `GOAL_STATUS: ...` marker.

### Subcommands

| command | effect |
| --- | --- |
| `/goal <objective>` | Start a bounded goal run with the default iteration cap. |
| `/goal --max-iterations N <objective>` | Start with an explicit cap. |
| `/goal status` | Print the current goal state. |
| `/goal stop` | Stop future autonomous iterations. |
| `/goal resume` | Resume the last non-running goal if it is still under its cap. |
| `/goal panel on\|off` | Show or hide the goal panel; bare `/goal panel` toggles it. |
| `/goal clear` | Clear the in-memory goal state. |

The default cap is intentionally conservative, and explicit caps are bounded so a goal run cannot become unbounded by default.
`/goal stop` does not cancel the currently running model turn; it marks the goal stopped so the turn-complete handler will not schedule another autonomous iteration.

### Iteration lifecycle

A goal run starts by submitting a hidden user turn through `api.turn.submit!`.
The extension records `running`, `iteration-count`, `max-iterations`, the objective, and the latest model result in its non-reloadable state module (`extensions/behaviors/companions/goal/state.fnl`).
When `:agent-turn-complete` fires, the extension reads the final `GOAL_STATUS` marker:

| marker | effect |
| --- | --- |
| `GOAL_STATUS: continue` | Start the next iteration if the cap has not been reached. |
| `GOAL_STATUS: done` | Mark the goal done. |
| `GOAL_STATUS: blocked` | Mark the goal blocked and leave recovery to the user. |
| `GOAL_STATUS: error` | Mark the goal errored. |

If the marker is missing, the run is marked blocked instead of guessing whether to continue.
If the marker asks to continue at the cap, the run is marked `cap-reached` and no further turn is submitted.
A cancelled turn marks the run stopped; a turn error marks it errored.

### Status, panel, and context warning

While a goal has visible state, the extension contributes a left-side status item such as `goal:1/3` or `goal:done`.
The optional panel shows the objective, iteration count, last reason, and a short preview of the latest result.
The extension also exposes an introspection snapshot for `/extensions goal` and `agent_state`.

Before submitting an iteration, `/goal` checks the same rough message-history token estimator used by the status line.
For the MVP it only warns when context is high and suggests manual `/compact`; automatic compaction and recovery are tracked separately by the compaction-aware goal work.

## Plan companion

The first-party `plan` extension (`extensions/behaviors/companions/plan/`) adds `/plan` for drafting, revising, inspecting, and approving execution plans.
While a plan or revision turn is running, its `before-tool` hook keeps the model in a read-only lane by allowing only `read`, `grep`, `find`, `ls`, `agent_state`, and `fen_docs`.
Mutating tools such as `bash`, `edit`, and `write` are blocked until the user approves the captured plan.
See [`tools.md`](tools.md) for what each of these tools does.

### Subcommands

`/plan` dispatches on its first argument; anything it does not recognize as a subcommand is treated as a new planning request.

| command | effect |
| --- | --- |
| `/plan` | Print usage. |
| `/plan <request>` | Draft a read-only plan for `<request>`, entering plan mode. |
| `/plan revise <notes>` | Revise the captured plan using `<notes>` as guidance, re-entering plan mode. |
| `/plan approve` | Execute the captured plan as a normal user turn. |
| `/plan show` | Print the captured plan (or a hint if none exists). |
| `/plan cancel` | Leave plan mode and clear the captured plan. |
| `/plan panel on\|off` | Show or hide the plan panel; bare `/plan panel` toggles it. |

`revise` and `approve` require a captured plan; without one they emit an error and do nothing.
Subcommand names are matched case-insensitively.

### Mode lifecycle

The extension tracks a small mode machine in its non-reloadable `state` module (`extensions/behaviors/companions/plan/state.fnl`):

```text
idle ──/plan <request>──► planning ──turn ok──► ready
                              ▲                   │
                              │                   ├──/plan approve──► idle
                         /plan revise             │
                              │                   │
                          revising ◄──────────────┘
                              │
                          turn ok──► ready
```

`planning` and `revising` are the two active read-only states (`planning?` is true in both), so the `before-tool` allowlist applies during a revision turn as well.
When a plan or revision turn completes successfully, `on-turn-complete` captures the result as `last-plan` and moves to `ready`.
`ready` means a plan has been captured and the model is no longer in the read-only lane; the extension is idle and waiting for the user to `approve`, `revise`, or `cancel`.
`approve` flips the mode back to `idle` *before* submitting, so the execution turn runs with normal tools available.
`cancel`, a cancelled turn, a failed turn, or an `:error`/`:reset-conversation` event all return the mode to `idle`.

### Status and panel

While a plan is active (any mode other than `idle`), the extension contributes UI state:

- A left-side `:status` item rendering `plan:<mode>` (for example `plan:planning` or `plan:ready`).
- An above-input `:panel` (`:order 34`) showing the current mode, the captured goal, a preview of the captured plan (truncated to a few lines), and the last tool blocked by the read-only hook.

The panel only renders when it is both active and visible; `/plan panel` toggles the visible flag, and `/plan panel on|off` sets it explicitly.

### Approving a plan

`/plan approve` submits the approved plan through `api.turn.submit!` as a normal user turn:

```text
Approved plan:

<plan text>

Execute this plan now.
```

That keeps turn/coroutine ownership inside the runtime instead of having the extension mutate presenter state directly.

> The read-only allowlist (`READ_ONLY_TOOLS` at the top of `init.fnl`) is hand-maintained.
> Tools carry no read-only/mutating metadata to derive it from, so the list is an explicit allowlist that fails safe: any tool not named there — including newly added inspection tools — is blocked while planning.
> Keep it in sync as new read-only tools land, or they will be unusable in plan mode.

## Subagents

The first-party `subagent` extension
(`extensions/behaviors/companions/subagent/`) registers a `subagent` tool that
delegates a focused task to a **child `fen` process** with its own context
window, a dedicated system prompt, and explicit provider/model routing.
The child's persona comes from either a discovered **named agent** file or an
inline **`prompt`** argument, so an agent file is convenient but not required
(see "Tool" below).
By default the child inherits the parent agent's provider and model when the
subagent tool context exposes them.
Agent frontmatter can override `model`, `provider`, or both.
A model-only override keeps the inherited provider and uses the frontmatter
model.
A provider+model override uses both frontmatter values.
A provider-only override passes the frontmatter provider and intentionally omits
the inherited model, so the child resolves that provider's default model through
normal CLI startup.
The child normally returns its final text, so long or self-contained work
(research, a scoped edit, a review pass) stays out of the parent's context.
If the child fails, times out, exits due to a signal, reports
`stop-reason = :error`, or writes missing/invalid JSON, the tool returns
visible diagnostic text instead of an empty result.
A successful child with empty `final-text` returns a non-error diagnostic
summary so callers can distinguish "no final text" from a failed child.

The design is out-of-process by composition over existing primitives: the child
is spawned via `process.run-captured` with the `json` presenter
(`--presenter json`) writing a structured result blob — `{final-text, messages,
usage, stop-reason, error}` — to the path named by `FEN_JSON_OUTPUT_PATH`.
The parent decodes that file and returns either the final text or diagnostic
text in the tool result, with metadata in `details`.
Diagnostic details include the agent, requested/effective/physical cwd,
effective provider/model, provider/model source, exit code, signal, timeout
flag, stop reason, duration, JSON status/error, event-stream status/count,
usage, output tail, output truncation flag, and full-output spill path when one
exists.
Cooperative yielding, timeouts, and abort all come from `run-captured`.

### Run status and cancellation

The subagent extension tracks active and recent child runs.
A status-line item appears while child runs are active, for example `subagent:1 running`.
Use `/subagents` to list active and recent runs with run id, agent, status, duration, cwd, task summary, and the latest recorded event for each run.
Children launched through the `json` presenter receive `FEN_SUBAGENT_EVENT_PATH` plus run identity environment variables and append bounded JSONL progress events for lifecycle, tool-call, tool-result, assistant text, and error events.
The parent drains that file cooperatively while `process.run-captured` yields, stores a bounded event tail in subagent state, and exposes it through `/subagents` plus the subagent introspector.
Missing or malformed event streams degrade to normal final-result diagnostics.
Use `/subagents steer RUN_ID NOTE` to add a steering note for an active run.
The first steering implementation is conservative: the running child process is terminated through the same cooperative cleanup path, then restarted with the original task plus the steering note.
Steering notes and restart events are recorded in the run event log and final diagnostics.
Use `/subagents cancel` to request cancellation for active child processes in the current turn.
This uses fen's normal cooperative turn cancellation path; `process.run-captured` terminates the child process group when cancellation reaches the running tool.
Subagent tool calls are still blocking from the model's perspective, so final results are collected only when the child exits.
There is no true background result-collection API yet.

### Agent discovery

Agents are markdown-with-frontmatter files, discovered like skills.
Roots, in precedence order (project beats user beats bundled):

- `./.fen/agents/*.md` — project
- `${XDG_CONFIG_HOME:-~/.config}/fen/agents/*.md` — user
- bundled default definitions — currently `scout`, `reviewer`, and `planner`

Use `/agents` to list the discovered agents, their project/user scope, explicit provider/model overrides, effective timeout, and description.
The subagent extension also adds a compact prompt fragment when agents exist and the `subagent` tool is available to the model.
It advertises only stable launch names and descriptions so the model can choose names for the `subagent` tool without receiving local paths or override details.
The fragment is capped; run `/agents` for the full discovered list.

An agent is launched by the `.md` filename (without extension).
The frontmatter `name:` is descriptive metadata and should normally match the filename.
Format:

```markdown
---
name: scout
description: Fast read-only recon
model: claude-haiku-4-5
provider: anthropic
timeout-seconds: 300
---
You are a scout. Briefly answer the question and stop.
```

`name` and `description` are required; `model`, `provider`, and
`timeout-seconds` are optional. Frontmatter values run to the end of the line,
so don't add inline `#` comments — they become part of the value. Omitting both
`model` and `provider` makes the child inherit the parent provider/model when
available.
Setting only `model` inherits the parent provider and uses that frontmatter
model.
Setting both `provider` and `model` pins both.
Setting only `provider` passes that provider and intentionally omits the parent
model, so the child uses normal CLI default-model resolution for that provider.
`timeout-seconds` defaults to 300.

The body becomes the child's system prompt (delivered with the `--system-file` CLI flag).
`models.json` custom providers work automatically because the child reads the same config directory.
Ready-to-use default agents `scout`, `reviewer`, and `planner` are bundled with fen.
Copy-pasteable source copies live in `extensions/behaviors/companions/subagent/examples/`.
Drop one into `.fen/agents/` or the user agents directory only when you want to customize or override the bundled definition.

### Tool

The `subagent` tool takes two kinds of arguments: one that says **who the child
is** (a named `agent` or an inline `prompt`) and one that says **what it should
do** (`task`), plus optional routing and cwd controls.

Parameters:

| Parameter | Required | Purpose |
| --- | --- | --- |
| `task` | always | The work handed to the child, delivered as its first user message. *What to do.* |
| `agent` | one of `agent`/`prompt` | Name of a discovered agent definition (the `.md` filename without extension). *Who the child is.* |
| `prompt` | one of `agent`/`prompt` | Inline system prompt used directly as the child's persona, so no agent file is needed. *Who the child is.* |
| `cwd` | optional | Working directory for the child; validated to exist. Defaults to the parent's cwd. |
| `model` | optional | Override the child model. Defaults to agent frontmatter, else the inherited parent model. |
| `provider` | optional | Override the child provider. A provider-only override omits the inherited model. |
| `timeout-seconds` | optional | Override the child timeout. Defaults to agent frontmatter, else 300. |

`task` names the job; `agent`/`prompt` name the persona — keep them distinct.
When both `agent` and `prompt` are supplied, the named agent wins.

Named agent:

```fennel
(subagent {:agent "scout"
           :task "what files define the provider interface?"
           :cwd "."})        ; cwd optional; validated to exist
```

Inline prompt — runs without any agent file, using the `prompt` as the child's
system prompt directly:

```fennel
(subagent {:prompt "You are a one-off reviewer. Answer briefly and stop."
           :task "summarize the risk in the current diff"
           :model "claude-haiku-4-5"   ; optional inline routing
           :provider "anthropic"        ; optional inline routing
           :timeout-seconds 120})       ; optional inline timeout
```

Inline `model`, `provider`, and `timeout-seconds` follow the same routing and
timeout policy as the equivalent agent frontmatter fields, so a provider-only
inline override also omits the inherited model.
Prefer a named agent when you want reviewable, reusable policy; use an inline
`prompt` for a quick one-off delegation that isn't worth a file.

> The `subagent` tool spawns `fen` itself, so its end-to-end behavior depends on
> the `json` presenter and the `--system-file`/`--presenter` flags. Because it
> also relies on the `spawn(argv, env)` path in the `fen_process` C binding,
> changes there require a full `nix build .#fen` / `make dev-nix` rather than a
> bare `/reload`.

## Simplify companion

The first-party `simplify` extension
(`extensions/behaviors/companions/simplify/`) adds `/simplify` for a
**quality-only** cleanup pass over changed code: reuse, simplification,
efficiency, and altitude.
It does not hunt for or fix bugs and does not change behavior; use a dedicated
bug-focused review for correctness.

It is composition over existing primitives.
The command computes the changed-file set (shelling git via `process.run-captured`) and submits a structured turn with `api.turn.submit!`.
The submitted prompt drives the main agent to fan out one read-only [`subagent`](#subagents) reviewer per changed file (using the bundled `simplifier` agent), consolidate the findings, discard anything risky or behavior-changing, then apply the safe simplifications and print a summary.
Subagents only review; the parent applies the edits so they stay coherent under one coordinator.

### Subcommands

| command | effect |
| --- | --- |
| `/simplify` | Review and apply quality cleanups on the current working-tree changes. |
| `/simplify <ref>` | Simplify changes since `<ref>` (for example `/simplify main`). |
| `/simplify show` | Reprint the last simplify summary. |
| `/simplify help` | Print usage. |

While a simplify turn runs, a left-side `simplify:running` status item is shown, and an `:introspect` snapshot exposes the status and last summary for `/extensions simplify`.
When git is unavailable or the directory is not a repo, the command still runs and asks the model to discover the diff itself; when there are no changes it exits early without starting a turn.

### The simplifier agent

`/simplify` delegates per-file review to a `simplifier` [agent](#agent-discovery).
A ready-to-use definition ships at
`extensions/behaviors/companions/simplify/examples/simplifier.md`; copy it into
`.fen/agents/` (project) or `${XDG_CONFIG_HOME:-~/.config}/fen/agents/` (user) to
enable isolated review.
If no `simplifier` agent is found the command prints a one-line hint and proceeds
with inline review instead, so it still works without the drop-in.

## Steering queue service

The first-party `steering` extension (`extensions/behaviors/kernel/steering/`)
owns the interactive input queues: steering lines injected into the running
turn at safe boundaries, and `>`-prefixed follow-up lines started as fresh
turns after the current turn completes.
Extracting it moved the queue tables, drain modes, and `>`-prefix policy out of
`main.fnl`'s run state (issue #53 phase 1); the run loop only wires the agent's
`get-steering`/`get-follow-up` callbacks and acts on the `:start` decision.

The service API lives in `fen.extensions.steering.service`:

| function | effect |
| --- | --- |
| `(submit line ctx)` | Decide non-slash input: `{:action :start}` when idle, else queue (steering, or follow-up after stripping `>`). |
| `(handle-input input ctx)` | Input-pipeline wrapper around `submit`; registered as the default `:input-handler` at order 1000 (see below). |
| `(get-steering)` / `(get-follow-up)` | Drain a queue by its mode; wired as the agent callbacks. |
| `(queue! kind text)` | Append a line and emit `:queued` plus refreshed status counts. |
| `(clear-queues! ?kind)` | Empty one queue or both (`/cancel-all`, `/new`, `/resume`, `/handoff`). |
| `(set-queue-mode! kind mode)` | `:one-at-a-time` (default) or `:all`. |
| `(queue-info)` / `(queue-snapshot)` | Counts+modes for status, copied contents for UI such as the `/queue` panel. |

Queue state lives in the non-reloadable `fen.extensions.steering.state`, so
pending input survives `/reload`.
Cross-extension consumers (the `/queue` inspector, sessions/handoff resets, the
`agent_state` tool) require the service module rather than the
`fen.extensions.steering` entry: the loader cache-busts entry modules on a
fresh `load!`, while non-entry modules keep one table identity that `/reload`
mutates in place.

### Input-handler pipeline

Non-slash user input is dispatched through an ordered `:input-handler` pipeline
before a turn starts (issue #53 phase 2), rather than through the notification
event bus — `api.emit` ignores return values, so it is a poor fit for ordered
input transforms/intercepts. The run loop calls
`fen.core.extensions.input.handle` with `{:kind :user-input :text line}` and
a small runtime-owned context `{:busy? bool :state runtime-state}`.

Handlers register with `(api.register :input-handler {:name ... :order ... :handle fn})`
and run in ascending `:order`. Each returns a structured action:

- `{:action :continue :input modified-input}` — pass (possibly transformed) input to the next handler.
- `{:action :consumed}` — swallow the input; no turn starts.
- `{:action :ignore}` — explicit no-op; stop the chain without starting a turn.
- `{:action :start :text text}` — start a new turn.
- `{:action :queued :queue :steering|:follow-up :text text}` — the handler already queued it.
- `{:action :error :error message}` — reject with a message.

The first non-`:continue` action wins; a handler that throws is skipped rather
than wedging input. If every handler passes, the runtime starts a turn with the
final text. The `steering` extension registers the default/fallback handler at
order 1000, so other extensions (macro expansion, planners, subagent routing)
can run before it.

## Reload behavior

`/reload` does two things:

1. reloads core modules listed by `packages/fen/src/fen/main.fnl`
2. asks `fen.core.extensions.loader` to reload each loaded extension

Every extension contribution is owner-tagged. Core stores this metadata in the
reserved internal field `:__owner`; public introspection lists expose it as
`:owner`. Do not put your own data in fields beginning with `__`.

Reload starts by removing all registrations for that owner, then re-runs the
entrypoint. The built-in `/reload` command runs this work from a coroutine and
passes a cooperative `yield!` callback into the loader so the TUI can keep
painting between core module batches and fully reloaded extension specs.
The active TUI presenter is skipped during the cooperative extension pass and then reloaded once at the end, followed by a single `:reinit-presenter` full redraw.

Extension code should follow the same rule: any command, hook, provider, tool,
or register-time operation that may block should accept a `?yield-fn` or use the
callback supplied by the runtime, and call it between chunks of work. Avoid long
CPU loops, blocking subprocess drains, large filesystem scans, or network waits
inside presenter callbacks without yielding.

For module-shaped extensions, the manifest controls what is cleared from
`package.loaded`:

```fennel
:reload-modules [:fen.extensions.tui.markdown
                 :fen.extensions.tui.paint
                 :fen.extensions.tui.input
                 :fen.extensions.tui]
:reload-exclude [:fen.extensions.tui.state]
```

This lets behavior reload while persistent state survives. The TUI uses this to
reload rendering/input/registration code while preserving termbox lifecycle,
transcript, scroll position, and status state.

`session-backend` unregister has one extra side effect: if the removed backend
is currently active, core clears the active backend and cached session info too.
Keeping a stale active backend reference would route later appends into removed
code.

Use `/reload-extension <name>` to reload one already-loaded external extension.
The command rebuilds the agent afterward so changed tools and prompt fragments
take effect while preserving conversation messages.

## Introspection

Interactive commands:

```text
/docs [topic] [name]
/extensions
/extensions <name>
/extensions registry [kind]
/reload-extension <name>
```

`/docs` browses runtime documentation from live registries and structured
contracts, including commands, tools, providers, events, canonical types, and
register kinds.
`/extensions <name>` shows manifest details plus the live commands, tools,
panels, status items, prompt fragments, event handlers, hooks, and other registry
contributions currently owned by that extension.
`/extensions registry [kind]` shows the live registry grouped by kind, with
stable owner labels for debugging reload cleanup and duplicate registrations.

Programmatic API:

```fennel
(api.list :extensions)
(api.list :commands)
(api.list :tools)
(api.list :presenters)
(api.list :event-handlers)
(api.list :prompt-fragments)
(api.list :status)
(api.list :panels)
(api.list :hooks)
```

Lists are frozen deep copies intended for inspection, not mutation.
Hot list kinds are memoized on a registry mutation counter, so repeated calls may return the same frozen snapshot until a register/unregister occurs.

## Packaging and dependencies

Flat manifest directories are the authoring shape for first-party and
project-local extensions. Rockspecs remain useful for publishing and declaring
extension dependencies, but users should build local extension dependencies via
fen rather than invoking LuaRocks directly:

```sh
fen ext build .fen/extensions/myext
```

`fen ext build DIR` expects exactly one `*.rockspec` in `DIR` and installs into
`${XDG_DATA_HOME:-~/.local/share}/fen/rocks` by default. Set `FEN_ROCKS_TREE` to
override the tree. Fen prepends the tree's Lua 5.4 `share/lua` and `lib/lua`
paths to the runtime search path on startup when the tree exists.

`fen ext build` compiles the extension's Fennel sources in process with the
embedded compiler (`fen.core.extensions.build`), so it needs neither a system
`fennel` nor a fen source checkout, then installs the result through the bundled
LuaRocks runtime. It drops a `.lrbuild/.fen-precompiled` marker so the rockspec's
own `build_command` skips its bootstrap compile. That `build_command` is a
one-line call into `scripts/build/fennel-build.fnl` for standalone `luarocks
make` builds without fen, which set `FEN_WORKSPACE` to the fen source root; the
single-file binary remains the canonical way to build extensions.

If extension loading fails with Lua's standard `module 'X' not found` error, the
loader surfaces an actionable message: `fen ext build <dir>` when the extension
directory has a rockspec, or a manual `luarocks install --tree ... X` command
when it does not. Manifests may optionally declare `:requires-modules [...]` to
probe lazy dependencies before loading and report all missing modules at once.
`:requires-shared-libs [...]` is diagnostic text only; fen does not install
system libraries.

The single-file binary bundles the local-only LuaRocks runtime, `lfs`, `dkjson`,
and the LuaSocket modules needed by first-party presenters, so pure-Lua local
rockspec builds do not need system `luarocks`. The bundled path intentionally
does not include LuaSec or the luarocks.org network/download workflow. Native
rocks still require a system C toolchain and Lua development headers; set `LUA`,
`LUA_INCDIR`, and related LuaRocks variables when needed.

## Minimal extension example

A path-shaped extension under your user config extension dir. No
`:entry-module`, no rock — just a directory with an `init.fnl` and, for global
discovery, a manifest that enables it.

```text
~/.config/fen/extensions/hello/
  manifest.fnl
  init.fnl
```

`manifest.fnl`:

```fennel
{:name :hello
 :description "Hello command"
 :enabled-by-default true}
```

`init.fnl`:

```fennel
(fn [api]
  (api.register :command
                {:name :hello
                 :description "Show a greeting"
                 :handler (fn [args _ctx]
                            (api.emit {:type :assistant-text
                                       :text (if (= args "")
                                                 "hello"
                                                 (.. "hello " args))}))}))
```

For a project-local version, place the same directory under
`.fen/extensions/hello/`; the manifest may be omitted entirely because the
extension name falls back to the directory name and project-local drop-ins are
enabled automatically.

For a tiny one-file project extension, use `.fen/extensions/hello.fnl`:

```fennel
(fn [api]
  (api.register :command
                {:name :hello
                 :description "Show a greeting"
                 :handler (fn [args _ctx]
                            (api.emit {:type :assistant-text
                                       :text (if (= args "")
                                                 "hello"
                                                 (.. "hello " args))}))}))
```

Run fen and type `/hello world`. In the source checkout, prefer the
single-file dev wrapper:

```sh
nix build .#fen
FEN_BIN=$PWD/result/bin/fen scripts/dev/fen-dev
```

Installed/package users can run `bin/fen` directly.

For ad-hoc testing of an extension dir that isn't on a discovery root:

```sh
FEN_BIN=$PWD/result/bin/fen scripts/dev/fen-dev --extension /path/to/hello
```

`--extension` accepts a manifest dir or a single `.fnl`/`.lua` file, and
always loads regardless of `:enabled-by-default`.
