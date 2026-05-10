---
name: fen-extension-author
description: Write, review, or debug fen extensions, including commands, tools, prompt fragments, hooks, panels, status items, manifests, reload behavior, and packaging.
---

# Fen Extension Author

Use this skill when creating, editing, reviewing, or debugging a `fen` extension.
It applies to project-local extensions, user-global extensions, and first-party in-tree extensions.

## First reads

Before making non-trivial changes, read the stable extension contract:

- `docs/extensions.md` for discovery, manifest fields, public API, register kinds, reload behavior, and examples.
- `docs/tools.md` when adding or changing an agent tool.
- `docs/development.md` for the dev/reload/test workflow.

If running inside fen with runtime docs available, prefer narrow contract lookups too:

- `fen_docs {topic: "register-kinds"}` to list register kinds.
- `fen_docs {topic: "register-kinds", name: "tool"}` for a specific register spec.
- `fen_docs {topic: "types", name: "AgentTool"}` or another canonical type as needed.
- `fen_docs {topic: "events"}` when publishing or subscribing to events.

## Authoring shape

Prefer a flat directory extension:

```text
my-extension/
  manifest.fnl   # optional for project-local drop-ins; recommended for reusable/global extensions
  init.fnl       # returns the register function
  state.fnl      # optional persistent state, when needed
```

A minimal entrypoint returns a function that receives `api`:

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

A reusable/global extension should usually include a `manifest.fnl`:

```fennel
{:name :hello
 :description "Hello command"
 :enabled-by-default true}
```

Project-local extensions under `.fen/extensions/<name>/` are enabled by intent and can omit the manifest when they only need `init.fnl`.

## API boundary

Use the loader-provided `api` as the public compatibility boundary.
Third-party extensions should avoid raw `fen.core.*` requires unless the needed capability is explicitly not public yet.

Public registration kinds are `:command`, `:tool`, `:hook`, `:status`, `:panel`, `:control`, and `:introspect`.
Use `api.prompt` for system-prompt fragments, `api.on` for event subscriptions, `api.emit` for events, and `api.load` for sibling files in path-backed extensions.
Infrastructure kinds such as providers, auth backends, session backends, and presenters are first-party/privileged unless the task explicitly concerns fen internals.

## Reload and state rules

Design for `/reload` from the start:

- Registration side effects should happen only inside the entrypoint register function.
- Do not call `unregister-by-owner`; the loader removes previous owner-tagged contributions before re-registering.
- Put long-lived mutable state in a small `state.fnl` module and list it in `:reload-exclude` when using module-shaped extensions.
- Put behavior/rendering/handlers in reloadable modules and list them in `:reload-modules`.
- Resolve behavior at call time for persistent callbacks where practical, rather than capturing stale function locals.
- Never write custom fields beginning with `__`; those are reserved for core owner metadata.

## Performance and cooperation

Keep presenter-facing callbacks cheap:

- `:status.render`, `:panel.height`, and `:panel.render` run every frame and should be side-effect-free.
- Do expensive work in commands, event handlers, or tools, cache the result in extension state, and render from the cache.
- Long filesystem scans, subprocess drains, network requests, and CPU loops should accept/pass a yield callback when the surrounding API provides one, and yield between chunks.

## Safety and introspection

- Tool specs should have clear `:description`, JSON-schema-ish `:parameters`, and deterministic `:execute` return values.
- Hooks that block work should return `{:block true :reason "..."}` with an actionable reason.
- Custom event types should be namespaced, e.g. `:my-ext/snapshot-created`.
- `:introspect` snapshots must be cheap, side-effect-free, non-blocking, JSON-friendly, and must not expose secrets.

## Testing workflow

Use the smallest useful check first:

```sh
fennel scripts/fennel-check.fnl
make test TESTS=extensions/path/to/tests/foo_test.fnl
make test
```

For live iteration in this repo:

```sh
make dev-nix
# edit .fnl, then use /reload or /reload-extension <name> in the TUI
```

For an ad-hoc extension outside discovery roots:

```sh
FEN_BIN=$PWD/result/bin/fen scripts/fen-dev --extension /path/to/my-extension
```

## Review checklist

Before calling an extension done, verify:

- The extension loads from the intended root and has the expected `:name` owner.
- `/extensions <name>` shows only the intended contributions.
- `/reload-extension <name>` does not duplicate commands, tools, panels, status items, hooks, event handlers, or prompt fragments.
- Tool and command handlers report user-facing errors instead of crashing on common bad inputs.
- Per-frame callbacks do not block, perform I/O, or mutate unrelated global state.
- Any persistent state is intentional and excluded from reload only when necessary.
- Docs or examples were updated if the extension adds stable behavior or public patterns.
