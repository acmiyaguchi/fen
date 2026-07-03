# Architecture notes

The stable contracts, module layout, and design principles behind fen's core.
For the day-to-day workflow and the full hot-reload model see
[`development.md`](development.md); the auto-generated API and contract reference
is indexed by the [generated sitemap](sitemap.html).

## Module map

```
packages/util/src/fen/util/                 JSON, HTTP, SSE, path, process, checksum helpers
packages/core/src/fen/core/types.fnl        Canonical Message/Tool/StopReason shapes
packages/core/src/fen/core/llm/             Provider registry, model config, stream accumulator
packages/core/src/fen/core/agent.fnl        Agent loop over canonical messages
packages/core/src/fen/core/tools.fnl        AgentTool executor/helpers
packages/core/src/fen/core/prompt.fnl       System-prompt fragment assembly
packages/core/src/fen/core/extensions/      Extension API, registry, loader, events, persistent state
packages/core/src/fen/core/settings.fnl     User preferences (~/.config/fen/settings.json)
packages/fen/src/fen/main.fnl               CLI entry: arg parse, provider dispatch, registration, reload
extensions/adapters/providers/              OpenAI family (Chat/Responses/Codex) and Anthropic Messages
extensions/adapters/presenters/tui/         Full-screen termbox2 presenter
extensions/adapters/session-backends/jsonl/ Append-only JSONL session backend
extensions/behaviors/kernel/                builtin-tools, default-prompt, essentials (/help, /model), docs (/docs)
extensions/behaviors/actions/sessions/      /new, /reload, /sessions, /resume
extensions/behaviors/inspectors/            status, queue, prompt, extensions panels
extensions/behaviors/companions/            skills, mem, agent-state, compact, todo, handoff, plan
scripts/dev/fen-dev                         Source-checkout dev wrapper for the single-file runtime
```

The repo tree is authoritative if it ever disagrees with this summary.
Dependency graphs (per-module, per-extension, subsystem) are generated under
`docs/generated/graphs/`; the [graph summary](generated/graphs/summary.md) lists
cycles and fan-in/fan-out hot spots (regenerate with `make graphs`).
Compiled `.lua` for Nix builds lands in gitignored package `dist/` trees — don't
check those in or hand-edit them.

## Reloadable microkernel

fen is a tiny core (agent loop, canonical types, provider dispatch, extension
registry) with providers, the TUI, session storage, and the built-in tools all
shipped as first-party extensions. `/reload` re-runs module bodies in place, so
most code lives in reloadable modules.

The contract that keeps reload safe: persistent identity lives in a few
non-reloadable state modules — `fen.extensions.tui.state` (termbox lifecycle,
transcript, scroll), `fen.core.extensions.state` (event bus, registries, prompt
fragments), and `fen.main` — and their reloadable siblings read and write through
them. The full rules (what reloads, cooperative yielding, idempotent
registration) live in
[`development.md`](development.md#hot-reload-is-the-development-loop).

## Canonical types and pi-mono divergence

All agent-side code operates on canonical message/tool shapes defined in
`packages/core/src/fen/core/types.fnl`; the field-level reference is generated
from source rather than restated here. Providers convert to and from wire shape
at the boundary, so the agent loop never sees provider-specific JSON — the
wire-shape differences are documented in [`providers.md`](providers.md).

Field naming is kebab-case in Fennel (`:tool-call-id`, `:stop-reason`,
`:is-error?`), semantically identical to pi-mono's camelCase; wire shapes stay
snake_case for JSON over HTTP.

Deliberately skipped vs pi-mono (added back only when a feature needs them):
ImageContent, `response-id` / `textSignature` / `thoughtSignature`, `usage.cost`,
`executionMode` / `signal` / `onUpdate` on tools, and `prepareArguments` / TypeBox
schema validation. ThinkingContent is kept — both Anthropic extended thinking and
OpenAI reasoning models surface it.

## Design principles

These shape the core API and what the generated docs cover. They are values, not
signatures, so they don't drift with the code the way restated facts do.

- **Strong, concise contracts.** While the design is small and local, prefer one
  clear public entry point over aliases, shims, legacy slots, or "just in case"
  wrappers; delete compatibility shims when call sites move.
- **One mechanism per job.** Reuse the events bus and existing register kinds
  before adding a new hook point, kind, queue, or reload path.
  Two overlapping mechanisms for one job is the failure mode this guards
  against (duplicated reload, hook-vs-events).
- **The core is the kernel only.** Agent loop, canonical types, provider
  dispatch, prompt assembly, tool execution, and the extension
  loader/registry/events belong in `packages/core`.
  Doc data, provider transport policy, and presenter logic live with their
  consumers.
- **Promote on second use.** A helper needed by two extensions moves to
  `fen.util.*` or a shared extension module rather than being copied;
  copy-paste is how the extension tree sprawls.
- **One spelling per command/API.** If `/prompt rendered` is the contract, don't
  also carry `/prompt full`, `--full`, or a `/prompt-fragments` alias.
- **Structured introspection.** Public metadata is named fields on records (a
  prompt fragment's `:id` / `:title` / `:description`), not text parsed back out
  of rendered output.
- **Narrow extension-facing surface.** Expose the smallest useful shape, and drop
  legacy concepts (prompt slots, per-slot render helpers) once a better
  abstraction lands.
- **Generated docs describe the supported surface, not every boundary-crossing
  helper.** Add `;; @doc` blocks for stable public contracts — canonical types,
  event shapes, register kinds, extension API helpers, provider/session/auth
  interfaces. Keep one-file helpers local; treat undocumented data/state exports
  as internal. Coverage is a signal, not the goal.
