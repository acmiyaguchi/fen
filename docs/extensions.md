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
| Extension source | `extensions/<name>/` (first-party) or user config dirs | Contributes behavior by calling the API |

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

## Discovery

Extensions are discovered by shallowly walking known roots for extension
directories and single-file entries. No hardcoded list of built-ins; first-party
and third-party use the same path.

Roots, in priority order (first match wins per name):

1. Explicit `--extension <path>` flags — single extension dir or single file
2. Project-local drop-ins — `.fen/extensions/` in the current directory and
   each ancestor up to the first `.git`/`.hg` worktree marker (or filesystem
   root if no marker exists)
3. User config — `$FEN_EXTENSIONS_PATH` (colon-separated) and
   `${XDG_CONFIG_HOME:-~/.config}/fen/extensions/`
4. First-party convention — `<prefix>/fen/extensions/` for each prefix
   extracted from `package.path` and `fennel.path` (covers packaged or rock
   installs), plus `extensions/` when running from a source checkout
   (workspace flat layout)

Discovery is shallow: only direct children of a root are considered. A
candidate may be either:

- a directory containing `manifest.{fnl,lua}` or `init.{fnl,lua}` (the typical shape)
- a single file `foo.fnl`/`foo.lua` — the file is the entry and the extension
  name comes from the basename

Project-local extensions are enabled by default even without
`:enabled-by-default true`, because placing an extension under a project's own
`.fen/extensions/` is treated as intent to run it. XDG/global discovered
extensions still honor `:enabled-by-default`; explicit `--extension <path>`
always loads regardless of that field.

In the canonical source-checkout workflow, `bin/fen-dev` passes
`--extension-root extensions` to the single-file runtime. First-party
flat extensions are loaded directly from `.fnl` source; no rebuild or `dist/`
mirror is required for reload-driven development.

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
| `:entry-module` | Lua module name resolved through `require`. The body runs at require time and self-registers via `(api.register …)`. Used by rock-shaped installs and compatibility packaging. |
| `:entry` | File path relative to the manifest dir. The file is `dofile`'d and its return value is preferably a register fn. `{:register fn}` remains accepted for older extensions but new code should return the function directly. Used by path-shaped (project drop-ins, single-file). |
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

## Entrypoint shape

Two shapes are honored. A manifest can choose explicitly; without a manifest,
the path-shaped `init.{fnl,lua}` fallback is used.

**Path-shaped** (`:entry` set, or fallback to `init.{fnl,lua}`). The file is
`dofile`'d; its return value should be a register function. The loader removes
prior owner-tagged contributions before invoking it, so normal path-shaped
extensions do not need to call `unregister-by-owner` themselves:

```fennel
(fn [api]
  (api.register :command
                {:name :hello
                 :description "Say hello"
                 :handler (fn [_args _ctx]
                            (api.emit {:type :info :text "hello"}))}))
```

A table with `:register` is still honored for compatibility, but is discouraged for new extensions:

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

Path-shaped extensions can load sibling files via `(api.load :state)` —
resolved relative to the manifest dir, no namespace required:

```fennel
(fn [api]
  (let [state (api.load :state)]   ; loads ./state.fnl or ./state.lua
    (api.register :command
                  {:name :hello :handler (fn [] (state.greet))})))
```

**Module-shaped** (`:entry-module` set). The named module is `require`'d; its
body self-registers. The loader removes prior owner-tagged contributions before
requiring the module, so the module body does not need explicit
`unregister-by-owner` boilerplate. First-party rocks use this shape.

```fennel
;; entry module body
(local extensions (require :fen.core.extensions))
(let [api (extensions.make-api :hello)]
  (api.register :command
                {:name :hello
                 :handler (fn [] (api.emit {:type :info :text "hello"}))}))
{}  ; module table — must return SOMETHING for require's cache
```

## API surface

The API table passed to an extension contains:

| method / field | purpose |
| --- | --- |
| `api.version` | Integer API version. Currently `1`. |
| `api.register(kind, spec)` | Register tools, commands, presenters, controls, hooks, status items, or panels. |
| `api.on(event-name, handler)` | Subscribe to event bus events. `:*` receives all events. |
| `api.emit(event-table)` | Publish an event. |
| `api.prompt(text-or-fn, opts)` | Add system-prompt fragments. |
| `api.list(kind)` | Frozen introspection lists. |
| `api.complete-once(agent, messages, ?model, ?opts, ?on-event, ?yield-fn)` | Run one provider completion using the live agent's provider configuration and empty tools. Useful for commands like `/handoff`. |
| `api.settings` | Settings proxy: `get`, `load!`, `set!`, `set-defaults!`. |
| `api.models` | Model registry proxy: `list`, `find`, `resolve`, `canonical-id`. |
| `api.agent-info(agent)` | Small read-only agent metadata: safety cap, provider/model, message count. |
| `api.types` | Canonical message/content constructors from `fen.core.types`. |
| `api.ui` | Active presenter UI slot helpers. |
| `api.load(name)` | Path-shaped extensions only: load `<manifest-dir>/<name>.{fnl,lua}` and return its value. Use for sibling files without a namespace. |

For third-party extensions, this API table is the compatibility contract. Raw
`fen.core.*` requires are private implementation details unless explicitly
surfaced above. First-party in-tree extensions may still require internals when
there is no public equivalent, but should prefer `api` as the boundary.

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

The underlying register kind is `:prompt-fragment`:

```fennel
(api.register :prompt-fragment
              {:id :my-extra-instruction
               :text "Extra instruction from my extension."
               :order 90})
```

Fragments are sorted by numeric `:order` and registration sequence, then joined
with blank lines. The first argument to `api.prompt` / the `:text` field may
also be a function evaluated with the prompt render context when the system
prompt is built. Failures degrade to an HTML comment instead of crashing prompt
assembly.

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

- `:llm-start`, `:llm-end`
- `:tool-call`, `:tool-result`
- `:assistant-text`, `:assistant-thinking`
- `:assistant-text-delta`, `:assistant-thinking-delta`, `:assistant-stream-end`
- `:user`, `:info`, `:queued`, `:error`, `:cancelled`
- `:extension-loaded`
- presenter-control events such as `:reset-conversation`, `:redraw`,
  `:set-status-info`
- `:dismiss` — emitted by the TUI on `Esc`; extensions owning a togglable
  panel should subscribe and close it (no-op when not displayed)

Custom event types should be namespaced by convention, e.g.
`:git-checkpoint/snapshot-created`.

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

The built-in TUI is a first-party extension under `extensions/tui/`.

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
(`extensions/tui/panels/busy.fnl`).

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
expensive work in event handlers and cache the result in extension
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

## Reload behavior

`/reload` does two things:

1. reloads core modules listed by `packages/fen/src/fen/main.fnl`
2. asks `fen.core.extensions.loader` to reload each loaded extension

Every extension contribution is owner-tagged. Core stores this metadata in the
reserved internal field `:__owner`; public introspection lists expose it as
`:owner`. Do not put your own data in fields beginning with `__`.

Reload starts by removing all registrations for that owner, then re-runs the
entrypoint.

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
/extensions
/reload-extension <name>
```

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
```

Lists are frozen deep copies intended for inspection, not mutation.

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

If extension loading fails with Lua's standard `module 'X' not found` error, the
loader surfaces an actionable message: `fen ext build <dir>` when the extension
directory has a rockspec, or a manual `luarocks install --tree ... X` command
when it does not. Manifests may optionally declare `:requires-modules [...]` to
probe lazy dependencies before loading and report all missing modules at once.
`:requires-shared-libs [...]` is diagnostic text only; fen does not install
system libraries.

The single-file binary bundles the local-only LuaRocks runtime, `lfs`, and
`dkjson` needed for this command, so pure-Lua local rockspec builds do not need
system `luarocks`. The bundled path intentionally does not include LuaSocket,
LuaSec, or the luarocks.org network/download workflow. Native rocks still
require a system C toolchain and Lua development headers; set `LUA`,
`LUA_INCDIR`, and related LuaRocks variables when needed.

## Minimal extension example

A path-shaped extension under your config dir. No `:entry-module`, no rock —
just a directory with an `init.fnl` and, for global discovery, a manifest that
enables it.

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
FEN_BIN=$PWD/result/bin/fen bin/fen-dev
```

Installed/package users can run `bin/fen` directly.

For ad-hoc testing of an extension dir that isn't on a discovery root:

```sh
FEN_BIN=$PWD/result/bin/fen bin/fen-dev --extension /path/to/hello
```

`--extension` accepts a manifest dir or a single `.fnl`/`.lua` file, and
always loads regardless of `:enabled-by-default`.
