---
name: fen-extension-author
description: Write, review, or debug fen extensions — commands, tools, hooks, status items, panels, and prompt fragments under .fen/extensions, ~/.config/fen/extensions, or fen's own extensions/ tree. Use when the user wants to add or change fen behavior through the extension API or asks why an extension does not load or reload.
---

# Fen Extension Author

Use this when creating, editing, reviewing, or debugging a `fen` extension: project-local, user-global, or first-party in-tree.

## First reads

Start with runtime docs; they describe the loaded binary and work without a source checkout:

```text
fen_docs {topic: "register-kinds"}
fen_docs {topic: "register-kinds", name: "tool"}
fen_docs {topic: "types", name: "AgentTool"}
fen_docs {topic: "events"}
```

If a fen source checkout is present, also read `docs/extensions.md` (discovery, manifests, reload, examples), `docs/tools.md` for agent tools, and `docs/development.md` for the dev/test loop.

## Extension shape

Prefer a flat directory:

```text
my-extension/
  manifest.fnl   # recommended for reusable/global extensions
  init.fnl       # returns the register function
  state.fnl      # optional persistent state
```

Minimal `init.fnl`:

```fennel
(fn [api]
  (api.register :command
                {:name :hello
                 :description "Show a greeting"
                 :handler (fn [args _ctx]
                            (api.emit {:type :assistant-text
                                       :text (if (= args "") "hello" (.. "hello " args))}))}))
```

Reusable/global `manifest.fnl`:

```fennel
{:name :hello
 :description "Hello command"
 :enabled-by-default true}
```

Project-local `.fen/extensions/<name>/` extensions are enabled by intent and can omit the manifest when `init.fnl` is enough.

## API boundary

Use the loader-provided `api` as the compatibility boundary.
Third-party extensions should avoid raw `fen.core.*` requires unless the needed capability is not public.

List the public register kinds with `fen_docs {topic: "register-kinds"}` rather than assuming a fixed set.
Use `api.prompt` for prompt fragments, `api.on` for event subscriptions, `api.emit` for events, and `api.load` for sibling files.
Providers, auth backends, session backends, and presenters are first-party/privileged unless the task concerns fen internals.

## Reload and state

Design for `/reload`:

- Register only inside the entrypoint function.
- Do not call `unregister-by-owner`; the loader cleans prior owner-tagged contributions.
- Put long-lived mutable state in `state.fnl` and exclude it from reload when needed.
- Put behavior/rendering/handlers in reloadable modules and list them in `:reload-modules`.
- Resolve behavior at call time for persistent callbacks where practical.
- Never write custom fields starting with `__`; core owns them.

## Performance and cooperation

- Keep `:status.render`, `:panel.height`, and `:panel.render` cheap, pure, and side-effect-free.
- Do expensive work in commands, event handlers, or tools; cache results in extension state.
- Long scans, subprocess drains, network requests, and CPU loops should accept/pass a yield callback when available and yield between chunks.

## Safety and introspection

- Tool specs need clear `:description`, JSON-schema-ish `:parameters`, and deterministic `:execute` results.
- Blocking hooks should return `{:block true :reason "..."}` with an actionable reason.
- Namespace custom events, e.g. `:my-ext/snapshot-created`.
- `:introspect` snapshots must be cheap, side-effect-free, non-blocking, JSON-friendly, and secret-free.

## Testing

For a project or user extension, edit its `.fnl` and run `/reload-extension <name>` (or `/reload`) in the running TUI.
Load an extension outside the discovery roots with `fen --extension /path/to/my-extension`.

Inside a fen source checkout:

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=extensions/path/to/tests/foo_test.fnl
make dev-nix    # then /reload after edits
```

## Review checklist

- Loads from the intended root with the expected owner name.
- `/extensions <name>` shows only intended contributions.
- `/reload-extension <name>` does not duplicate contributions.
- Tool/command handlers return user-facing errors for common bad inputs.
- Per-frame callbacks do not block, do I/O, or mutate unrelated global state.
- Persistent state is intentional and reload-excluded only when necessary.
- Docs/examples changed if stable behavior or public patterns changed.
