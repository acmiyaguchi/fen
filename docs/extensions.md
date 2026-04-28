# Extensions

agent-fennel has a small Lua/Fennel extension system for adding behavior around
the core agent loop without patching `src/core/` directly. Extensions can add
slash commands, tools, hooks, system-prompt fragments, event subscribers, and
presenters.

The extension system is intentionally a **soft plugin boundary**: extensions run
inside the same Lua VM as the agent and have normal host access. Install only
extensions you trust.

## Mental model

There are three pieces:

| piece | path | role |
| --- | --- | --- |
| Extension API / registries | `src/core/extensions.fnl` | Event bus, command/tool/presenter registries, UI slot, lifecycle dispatch |
| Extension loader | `src/core/extension_loader.fnl` | Discovers extensions, reads manifests, checks deps, reloads modules |
| Extension source | `src/extensions/<name>/` or user config dirs | Contributes behavior by calling the API |

An extension usually has two files:

```text
my-extension/
  manifest.fnl   # metadata for the loader
  init.fnl       # runtime registration entrypoint
```

Short version:

```text
manifest.fnl = how to load/reload/describe the extension
init.fnl     = what the extension actually does once loaded
```

## Discovery

External extensions are discovered from:

1. `$FEN_EXTENSIONS_PATH` — colon-separated roots
2. `${XDG_CONFIG_HOME:-~/.config}/fen/extensions/`
3. `${XDG_CONFIG_HOME:-~/.config}/agent-fennel/extensions/`
4. explicit `--extension <path>` flags

A discovered entry may be either:

- a file: `foo.fnl` or `foo.lua`
- a directory containing `init.fnl` or `init.lua`

Hidden and underscored entries are skipped during directory discovery:

```text
.foo/      # skipped
_foo/      # skipped
foo/       # considered
```

Duplicate names are first-seen-wins; later duplicates are skipped with a warning.
Explicit `--extension <path>` entries are enabled regardless of
`:enabled-by-default`.

## Manifest

Directory extensions may include `manifest.fnl` or `manifest.lua`. First-party
extensions also use manifests. A Fennel manifest is just a table:

```fennel
{:name :hello
 :description "Example extension"
 :enabled-by-default true
 :requires {:lua [:lfs]
            :bin ["git"]}
 :reload-modules [:extensions.hello.helper
                  :extensions.hello]
 :reload-exclude [:extensions.hello.state]}
```

Fields:

| field | meaning |
| --- | --- |
| `:name` | Extension owner/name used for introspection and teardown. Falls back to file/dir name. |
| `:description` | Human-readable description. |
| `:enabled-by-default` | Whether discovered extensions load automatically. Explicit `--extension` always loads. |
| `:requires.lua` | Lua modules that must be require-able before enabling. |
| `:requires.bin` | Binaries that must exist on `PATH` before enabling. |
| `:reload-modules` | Module names to clear from `package.loaded` on reload. |
| `:reload-exclude` | Module names to preserve even if listed or otherwise known. Use for persistent state. |

The loader records disabled, missing-dependency, loaded, and error states for
`/extensions` and `api.list :extensions`.

## Entrypoint shape

`init.fnl` should return either a function:

```fennel
(fn [api]
  (api.register :command
                {:name :hello
                 :description "Say hello"
                 :handler (fn [_args _ctx]
                            (api.emit {:type :info :text "hello"}))}))
```

or a table with `:register`:

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

## API surface

The API table passed to an extension contains:

| method / field | purpose |
| --- | --- |
| `api.version` | Integer API version. Currently `1`. |
| `api.register(kind, spec)` | Register tools, commands, presenters, or hooks. |
| `api.on(event-name, handler)` | Subscribe to event bus events. `:*` receives all events. |
| `api.emit(event-table)` | Publish an event. |
| `api.contribute-system-prompt(text-or-fn, opts)` | Add system-prompt fragments. |
| `api.list(kind)` | Frozen introspection lists. |
| `api.describe-extension(name)` | Frozen extension status record. |
| `api.ui` | Active presenter UI slot helpers. |

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

Tool specs match the built-in `AgentTool` shape from `src/core/tools/init.fnl`:

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
(api.contribute-system-prompt
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

The built-in TUI is a first-party extension under `src/extensions/tui/`.

## Reload behavior

`/reload` does two things:

1. reloads core modules listed by `main.fnl`
2. asks `core.extension_loader` to reload extensions

Every extension contribution is owner-tagged. Reload starts by removing all
registrations for that owner, then re-runs the entrypoint.

For modules, the manifest controls what is cleared from `package.loaded`:

```fennel
:reload-modules [:extensions.tui.markdown
                 :extensions.tui.paint
                 :extensions.tui.input
                 :extensions.tui]
:reload-exclude [:extensions.tui.state]
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
(api.list :system-prompt-contributions)
(api.describe-extension :hello)
```

Lists are frozen deep copies intended for inspection, not mutation.

## Minimal extension example

```text
~/.config/agent-fennel/extensions/hello/
  manifest.fnl
  init.fnl
```

`manifest.fnl`:

```fennel
{:name :hello
 :description "Hello command"
 :enabled-by-default true
 :reload-modules [:hello]}
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

Then run:

```sh
make build
bin/agent-fennel
```

and type:

```text
/hello world
```

For ad-hoc testing without enabling by default:

```sh
bin/agent-fennel --extension /path/to/hello
```
