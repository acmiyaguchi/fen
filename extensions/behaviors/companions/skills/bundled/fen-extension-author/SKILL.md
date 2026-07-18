---
name: fen-extension-author
description: Write, review, or debug Fen extensions.
---

# Fen Extension Author

Use this when creating, editing, reviewing, or debugging a `fen` extension: project-local, user-global, or first-party in-tree.

## First reads

For non-trivial changes, read:

- `docs/extensions.md` for discovery, manifests, API, register kinds, reload, and examples.
- `docs/tools.md` when adding/changing an agent tool.
- `docs/development.md` for dev/reload/test workflow.

Runtime docs are also useful:

```text
fen_docs {topic: "register-kinds"}
fen_docs {topic: "register-kinds", name: "tool"}
fen_docs {topic: "types", name: "AgentTool"}
fen_docs {topic: "events"}
```

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

Public kinds: `:command`, `:tool`, `:hook`, `:status`, `:panel`, `:control`, `:introspect`.
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

```sh
fennel scripts/test/fennel-check.fnl
make test TESTS=extensions/path/to/tests/foo_test.fnl
make test
```

Live iteration:

```sh
make dev-nix
# edit .fnl, then /reload or /reload-extension <name>
```

Ad-hoc extension outside discovery roots:

```sh
FEN_BIN=$PWD/result/bin/fen scripts/dev/fen-dev --extension /path/to/my-extension
```

## Review checklist

- Loads from the intended root with the expected owner name.
- `/extensions <name>` shows only intended contributions.
- `/reload-extension <name>` does not duplicate contributions.
- Tool/command handlers return user-facing errors for common bad inputs.
- Per-frame callbacks do not block, do I/O, or mutate unrelated global state.
- Persistent state is intentional and reload-excluded only when necessary.
- Docs/examples changed if stable behavior or public patterns changed.
