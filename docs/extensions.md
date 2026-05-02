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
| Extension loader | `packages/core/src/fen/core/extensions/loader/` | Walks roots for manifests, checks deps, loads/reloads each spec |
| Extension source | `packages/extensions/<name>/` (first-party) or user config dirs | Contributes behavior by calling the API |

An extension is a directory with a manifest and an entry:

```text
my-extension/
  manifest.fnl   # metadata for the loader
  init.fnl       # runtime registration entrypoint (default; manifest can override)
```

Short version:

```text
manifest.fnl = how to load/reload/describe the extension
init.fnl     = what the extension actually does once loaded
```

The `fen.extensions.*` namespace is a convention for first-party rocks, not a
structural requirement. Third-party extensions may pick any namespace, and
project-local drop-ins need no namespace at all — the manifest decides.

## Discovery

Extensions are discovered by walking roots for `manifest.{fnl,lua}` files. No
hardcoded list of built-ins; first-party and third-party use the same path.

Roots, in priority order (first match wins per name):

1. Explicit `--extension <path>` flags — single extension dir or single file
2. User config — `$FEN_EXTENSIONS_PATH` (colon-separated) and
   `${XDG_CONFIG_HOME:-~/.config}/fen/extensions/`
3. First-party convention — `<prefix>/fen/extensions/` for each prefix
   extracted from `package.path` and `fennel.path` (covers packaged or rock
   installs), plus `packages/extensions/` when running from a source checkout
   (workspace flat layout)

A discovered entry may be either:

- a directory containing `manifest.{fnl,lua}` (the typical shape)
- a single file `foo.fnl`/`foo.lua` (`--extension <path>` only — the file is
  the entry, name comes from the basename)

In the canonical source-checkout workflow, `bin/fen-dev` passes
`--extension-root packages/extensions` to the single-file runtime. First-party
flat extensions are loaded directly from `.fnl` source; no `make build` or
`dist/` mirror is required for reload-driven development.

Hidden and underscored directory entries are skipped during root walks:

```text
.foo/      # skipped
_foo/      # skipped
foo/       # considered
```

Duplicate names are first-seen-wins; later duplicates are skipped silently.
Explicit `--extension <path>` entries are enabled regardless of
`:enabled-by-default`.

## Manifest

Every directory extension declares a `manifest.fnl` (or `manifest.lua`) at its
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
| `:entry` | File path relative to the manifest dir. The file is `dofile`'d and its return value is a register fn or `{:register fn}`. Used by path-shaped (project drop-ins, single-file). |
| `:requires.lua` | Lua modules that must be require-able before enabling. |
| `:requires.bin` | Binaries that must exist on `PATH` before enabling. |
| `:reload-modules` | Module names to clear from `package.loaded` on reload. |
| `:reload-exclude` | Module names to preserve even if listed or otherwise known. Use for persistent state. |

If neither `:entry-module` nor `:entry` is set, the loader falls back to
`<dir>/init.{fnl,lua}` as the path-shaped entry.

The loader records disabled, missing-dependency, loaded, and error states for
`/extensions` and `api.list :extensions`.

## Entrypoint shape

Two shapes are honored, chosen by the manifest.

**Path-shaped** (`:entry` set, or fallback to `init.{fnl,lua}`). The file is
`dofile`'d; its return value must be a register function:

```fennel
(fn [api]
  (api.register :command
                {:name :hello
                 :description "Say hello"
                 :handler (fn [_args _ctx]
                            (api.emit {:type :info :text "hello"}))}))
```

…or a table with `:register`:

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
body runs once and self-registers. The body is responsible for keeping reload
idempotent — typically by calling `(extensions.unregister-by-owner :name)`
before re-registering. First-party rocks use this shape.

```fennel
;; entry module body
(local extensions (require :fen.core.extensions))
(extensions.unregister-by-owner :hello)
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
| `api.ui` | Active presenter UI slot helpers. |
| `api.load(name)` | Path-shaped extensions only: load `<manifest-dir>/<name>.{fnl,lua}` and return its value. Use for sibling files without a namespace. |

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

```fennel
(api.prompt
  "Extra instruction from my extension."
  {:slot :end})
```

Slots are:

- `:before-body`
- `:before-context`
- `:end`

The first argument may also be a function, evaluated when the system prompt is
built. Failures degrade to an HTML comment instead of crashing prompt assembly.

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

The built-in TUI is a first-party extension under `packages/extensions/tui/`.

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
(`packages/extensions/tui/panels/busy.fnl`).

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

Every extension contribution is owner-tagged. Reload starts by removing all
registrations for that owner, then re-runs the entrypoint.

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
project-local extensions. Rockspecs and LuaRocks remain useful for publishing
or installing dependencies, but they are not the canonical source-editing loop.
While #68 is open, dependency-bearing extensions may still document manual
LuaRocks commands. The intended user-facing command is `fen ext build <dir>`;
once that lands, normal users should not need to invoke `luarocks make`
directly.

## Minimal extension example

A path-shaped extension under your config dir. No `:entry-module`, no rock —
just a manifest dir with an `init.fnl` next to it.

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

Run fen and type `/hello world`. In the source checkout, prefer the
single-file dev wrapper:

```sh
nix build .#fenSingle
FEN_BIN=$PWD/result/bin/fen bin/fen-dev
```

Installed/package users can run `bin/fen` directly.

For ad-hoc testing of an extension dir that isn't on a discovery root:

```sh
FEN_BIN=$PWD/result/bin/fen bin/fen-dev --extension /path/to/hello
```

`--extension` accepts a manifest dir or a single `.fnl`/`.lua` file, and
always loads regardless of `:enabled-by-default`.
