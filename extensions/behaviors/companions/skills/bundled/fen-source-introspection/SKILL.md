---
name: fen-source-introspection
description: Inspect Fen internals, runtime contracts, and live registries.
---

# Fen Source Introspection

Use this when asked how fen works internally, where behavior lives, what an interface/extension contract looks like, or how to inspect source/distribution details.

## Prefer runtime docs

In a distributed binary, source files may not be present.
Start with runtime docs and live registries; they reflect the loaded binary/extensions.

Useful `fen_docs` queries:

```text
fen_docs {topic: "topics"}
fen_docs {topic: "commands"}
fen_docs {topic: "tools"}
fen_docs {topic: "register-kinds"}
fen_docs {topic: "register-kinds", name: "tool"}
fen_docs {topic: "types", name: "AgentTool"}
fen_docs {topic: "events"}
fen_docs {topic: "extensions"}
fen_docs {query: "session backend"}
```

Common topics: `commands`, `tools`, `providers`, `events`, `types`, `register-kinds`, `extensions`.
Inside the TUI, `/docs`, `/docs <topic>`, and `/docs <topic> <name>` expose the same information.

## Inspect live state when needed

Use `agent_state` narrowly instead of guessing:

```text
agent_state {query: "(:get :model)"}
agent_state {query: "(:pluck (:get :tools) :name)"}
agent_state {query: "(:get :extensions)"}
agent_state {query: "(:last (:where (:get :messages) :role :assistant))"}
```

Use docs/registries before broad state dumps.

## Source checkout map

If source is present, start with:

- `CLAUDE.md` — repo workflow and pointers.
- `docs/architecture.md` — package/module architecture.
- `docs/extensions.md` — extension API, discovery, reload, register kinds.
- `docs/tools.md` — built-in tool contracts.
- `docs/providers.md` — provider interface and model config.
- `docs/sessions.md` — JSONL session format.
- `docs/skills.md` — skill discovery and prompt behavior.

Important roots:

```text
packages/core/src/fen/core/          core agent, tools, prompt, extensions, docs contracts
packages/fen/src/fen/main.fnl        CLI entrypoint, reload lists, option parsing
packages/util/src/fen/util/          path, JSON, HTTP, process, checksum helpers
extensions/adapters/                 providers, presenters, session/auth adapters
extensions/behaviors/                commands, tools, prompt fragments, panels, status, hooks
scripts/                             build, tests, docs generation, smoke scripts
nix/                                 packaging, checks, distribution artifacts
```

Use `find`/`grep` before opening many files:

```text
find packages -name "*.fnl"
grep packages -glob "*.fnl" -pattern "register :tool"
grep extensions -glob "*.fnl" -pattern "api.register"
```

Then read only relevant files/ranges.

## If source is absent

Say so clearly.
Do not pretend embedded source files are normal filesystem files.
Answer from `fen_docs`, `agent_state`, `/docs`, and live registries.
Ask for a checkout/path if implementation details are needed.

## Extension/interface checklist

1. Read `docs/extensions.md` or `fen_docs {topic: "register-kinds"}`.
2. Inspect the specific kind: `command`, `tool`, `panel`, `status`, `hook`, `introspect`, etc.
3. Check ownership with `/extensions <name>` or `fen_docs {topic: "extensions"}`.
4. Check live tools/commands/panels/status via `fen_docs` or `api.list` examples.
5. If source is present, read the owning extension and nearby tests.

## Answer style

- Distinguish stable public contracts from private implementation details.
- Prefer paths and exact register/type names.
- Mention whether the answer comes from runtime docs, live state, or source.
- For distributed binaries, favor contract-level answers unless source files are available.
