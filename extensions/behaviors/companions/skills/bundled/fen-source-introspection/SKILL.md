---
name: fen-source-introspection
description: Inspect fen internals, source code, runtime docs, extension contracts, live registries, and interfaces when answering questions about how fen works.
---

# Fen Source Introspection

Use this skill when the user asks how fen works internally, where a behavior lives, what an interface or extension contract looks like, or how to inspect source/distribution details.

## Prefer runtime docs first

In a distributed fen binary, the original source checkout may not be present as files the `read` tool can open.
Start with runtime docs and live registries because they are available from the running agent and reflect the loaded binary/extensions.

Use narrow `fen_docs` queries:

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

Useful topics commonly include:

- `commands` — live slash commands
- `tools` — live agent tools
- `providers` — model/provider adapters
- `events` — event bus shapes
- `types` — canonical data/interface types
- `register-kinds` — extension registration contracts
- `extensions` — loaded extension specs and ownership

Inside the TUI, `/docs`, `/docs <topic>`, and `/docs <topic> <name>` expose the same family of information.

## Inspect live state when needed

Use `agent_state` for read-only runtime state instead of guessing.
Prefer narrow queries:

```text
agent_state {query: "(:get :model)"}
agent_state {query: "(:pluck (:get :tools) :name)"}
agent_state {query: "(:get :extensions)"}
agent_state {query: "(:last (:where (:get :messages) :role :assistant))"}
```

Do not dump large roots unless necessary.
Use registry/doc queries before broad state queries.

## Reading source in a checkout

If the user is running from a source checkout, then normal file tools can inspect source.
Start with these stable maps:

- `CLAUDE.md` — repository workflow and module map pointers
- `docs/architecture.md` — package/module architecture
- `docs/extensions.md` — extension API, discovery, reload, and register kinds
- `docs/tools.md` — built-in tool contracts
- `docs/providers.md` — provider interface and model config
- `docs/sessions.md` — JSONL session format
- `docs/skills.md` — Agent Skills discovery and prompt behavior

Important source roots:

```text
packages/core/src/fen/core/          core agent, tools, prompt, extensions, docs contracts
packages/fen/src/fen/main.fnl        CLI entrypoint, reload lists, option parsing
packages/util/src/fen/util/          path, JSON, HTTP, process, checksum helpers
extensions/adapters/                 first-party providers, presenters, session/auth adapters
extensions/behaviors/                commands, tools, prompt fragments, panels, status, hooks
scripts/                             build, tests, docs generation, smoke scripts
nix/                                 packaging, checks, distribution artifacts
```

Use `find` and `grep` before opening many files:

```text
find packages -name "*.fnl"
grep packages -glob "*.fnl" -pattern "register :tool"
grep extensions -glob "*.fnl" -pattern "api.register"
```

Then read only the relevant files and ranges.

## When source is not present

If `read`/`find` cannot see the fen checkout, say so clearly.
Do not pretend embedded source files are normal filesystem files.
Use `fen_docs`, `agent_state`, `/docs`, and live registry information to answer what you can.
If the user needs implementation details beyond runtime docs, ask for a source checkout or a path to the relevant files.

## Extension/interface investigation checklist

For extension authoring or debugging questions:

1. Read `docs/extensions.md` when available, or use `fen_docs {topic: "register-kinds"}`.
2. Inspect the specific register kind contract, e.g. `command`, `tool`, `panel`, `status`, `hook`, or `introspect`.
3. Check live ownership with `/extensions <name>` or `fen_docs {topic: "extensions"}`.
4. Check live tools/commands/panels/status items through `fen_docs` or `api.list` examples in the docs.
5. If source is present, read the owning extension under `extensions/` and any tests next to it.

## Answering style

- Distinguish stable public contracts from private implementation details.
- Prefer paths and exact register/type names over vague descriptions.
- Mention whether the answer came from runtime docs, live state, or source files.
- For distributed binaries, favor contract-level answers unless source files are actually available.
