# Architecture notes

This page captures the stable core contracts and architecture constraints for fen.

## What this is

A small AI coding-agent CLI written in Fennel, compiled to Lua. Mirrors
pi-mono's interface shapes (canonical Message types, provider abstraction,
agent loop) in vastly simplified form. Targets Lua 5.4 on ARMv7 (Raspberry
Pi-class hardware).


## Module map

```
packages/util/src/fen/util/                         JSON, HTTP, SSE, path,
                                                     process, checksum helpers
packages/core/src/fen/core/types.fnl                Canonical Message/Tool/StopReason
packages/core/src/fen/core/llm/                     Provider registry, model config,
                                                     event stream accumulator
packages/core/src/fen/core/agent.fnl                Agent loop on canonical messages
packages/core/src/fen/core/tools.fnl                AgentTool executor/helpers
packages/core/src/fen/core/prompt.fnl               System-prompt fragment assembly
packages/core/src/fen/core/extensions/              Extension API, registry, loader,
                                                     events, persistent state
extensions/adapters/session-backends/jsonl/       Append-only JSONL session backend
packages/core/src/fen/core/settings.fnl             User preferences in
                                                     ~/.config/fen/settings.json
extensions/adapters/providers/openai/     OpenAI provider family: Chat Completions,
                                           Responses, Codex subscription, and Codex auth
extensions/adapters/providers/anthropic/  Anthropic Messages provider extension
extensions/adapters/presenters/tui/       Full-screen termbox2 presenter
extensions/behaviors/kernel/builtin-tools/ Built-in bash/read/write/ls/edit/grep/find
extensions/behaviors/kernel/default-prompt/ Cwd/date/tools/project prompt policy
extensions/behaviors/kernel/essentials/  /help and /model commands
extensions/behaviors/actions/sessions/   /new, /reload, /sessions, /resume
extensions/behaviors/inspectors/         Status, queue, prompt, and extension panels
extensions/behaviors/companions/         skills, mem, agent-state, and handoff
packages/fen/src/fen/main.fnl                      CLI entry: arg parse, provider dispatch,
                                                    first-party registration, reload
scripts/fen-dev                                        Source-checkout dev wrapper for the single-file runtime
```

Generated Graphviz source lives under `docs/generated/graphs/`.
Regenerate DOT, SVG renderings, and the graph summary with `make graphs`.
SVG files are intentionally generated locally rather than tracked in Git.

The generated [`summary.md`](generated/graphs/summary.md) lists cycles and fan-in/fan-out hot spots.
The docs-facing subsystem graph source is [`subsystems.dot`](generated/graphs/subsystems.dot).
The full module graph source is [`modules.dot`](generated/graphs/modules.dot), with a clustered variant at
[`modules-clustered.dot`](generated/graphs/modules-clustered.dot).
Per-extension graph sources live under `docs/generated/graphs/extensions/`.

Compiled `.lua` for the Nix-built binary lands in package `dist/` trees inside
build sandboxes. Local package `dist/` directories are gitignored — don't check
them in or hand-edit them.


## Canonical types (the contract)

All agent-side code operates on canonical message/tool shapes defined in
`packages/core/src/fen/core/types.fnl`. Providers convert to/from wire shape on the boundary;
the agent loop never sees provider-specific JSON.

Field naming: kebab-case in Fennel (`:tool-call-id`, `:stop-reason`,
`:is-error?`); semantically identical to pi-mono's camelCase. Wire shapes
stay snake_case (they're going through JSON over HTTP).

Skipped vs pi-mono (additive when needed): ImageContent, response-id /
textSignature / thoughtSignature, usage.cost, executionMode / signal /
onUpdate on tools, prepareArguments / TypeBox schema validation. We DO
include ThinkingContent — both Anthropic extended thinking and OpenAI
reasoning models surface it.


## Core API philosophy

Build aggressively toward **strong, concise contracts** in core modules.
This repo does not need long-lived backwards-compatible compatibility
surfaces while the design is still small and local. Prefer one clear public
entry point over aliases, shims, legacy slots, or "just in case" wrappers.

Guidelines:

- **Delete compatibility shims when call sites move.** Do not keep old module
  paths, command aliases, or adapter functions unless there is an active,
  documented external consumer.
- **Make introspection explicit and structured.** Public metadata should be
  named fields on records, not inferred from rendered text. For example,
  prompt fragments use `:id`, `:title`, and `:description` for inspection;
  rendered prompt text remains controlled by the fragment itself.
- **Prefer a single command/API spelling.** If `/prompt rendered` is the
  contract, avoid also supporting `/prompt full`, `--full`, or a separate
  `/prompt-fragments` alias.
- **Keep core behavior narrow.** Extension-facing APIs should expose the
  smallest useful shape. Avoid preserving legacy concepts like prompt slots or
  per-slot render helpers once ordered fragments are the real abstraction.
- **Tests should follow the new contract, not freeze legacy behavior.** When
  simplifying an API, update tests to assert the desired concise surface rather
  than carrying compatibility expectations forward.


## Public API and generated documentation policy

Generated docs should describe the supported surface, not every implementation detail that happens to cross a module boundary.
Use this policy when deciding whether to add an inline `;; @doc` block or change the scanner/generator:

- **Document stable public contracts.** Canonical types, event shapes, register kinds, extension API helpers, provider/session/auth interfaces, and intentionally exported core entry points should have structured contracts or `;; @doc` blocks.
- **Keep internals local when practical.** If a helper is only used inside one file, prefer a local binding over exporting it.
  If it must be exported for reload wiring, tests, or cross-module organization, do not make it look public solely to raise coverage.
- **Treat undocumented data exports as internal by default.** State-table aliases such as registries and handler buckets are implementation plumbing.
  Generated API docs fold undocumented data/state re-exports instead of rendering each one as a public item.
  Document data exports only when they are intentional constants or stable records, such as `SAFETY-CAP`.
- **Extension entrypoints are documented through behavior.** A first-party extension's `register` function may remain an internal entrypoint.
  The contributed commands/tools/providers/panels should carry names and descriptions, and their register-kind contracts should be documented.
- **Coverage is a signal, not the goal.** Function coverage answers whether the browsable API is useful; contract coverage answers whether extension authors have a spec.
  Prefer fewer accurate public docs over many generic summaries for private helpers.

## Conventions / gotchas

- **Auth headers differ per provider.** OpenAI uses
  `Authorization: Bearer <key>`. Anthropic uses `x-api-key: <key>` plus
  `anthropic-version: 2023-06-01`. Owned by the provider modules.
- **System prompt placement differs.** OpenAI inlines as
  `messages[0].role:"system"`. Anthropic uses a top-level `system` field.
  The agent always carries `system-prompt` separately on `AgentContext`;
  providers handle the placement.
- **Tool result shape differs.** OpenAI: a `{role:"tool", tool_call_id,
  content}` message of its own. Anthropic: nested inside a `{role:"user"}`
  message as a `tool_result` content block. Anthropic provider batches
  consecutive `:tool-result` canonical messages into one user message.
- **Tool args are parsed objects in the canonical type**, not JSON strings.
  Each provider's `parse-response` JSON-decodes the wire arguments before
  building the canonical `:tool-call` block; tool `execute` receives a
  ready-to-use Lua table.
- **All HTTP goes through `fen.util.http.request`.** The transport is
  `fen_http.so`, a project-owned libcurl C binding built from
  `packages/util/vendor/fen_http.c`. The `lua-curl` rock is no longer a
  dependency. lua-cjson is still loaded as `cjson`.
- **Don't reintroduce lcurses.** Caps at Lua `<5.4`, isn't in nixpkgs as a
  Lua 5.4 rock, forces a 5.2 toolchain. The TUI is intentionally termbox2,
  with the tiny Lua binding vendored in `extensions/adapters/presenters/tui/vendor/` and
  built into `extensions/adapters/presenters/tui/dist/termbox2.so`.
- **Termbox2 lifecycle state lives in
  `extensions/adapters/presenters/tui/state.fnl`** and bus
  subscriptions / extension registries live in
  `packages/core/src/fen/core/extensions/state.fnl`. Both are excluded from
  `RELOADABLE`; their reloadable siblings read and write through them. See the
  "Hot reload" section above for the full rule.
- **Markdown rendering exists.** Assistant text is rendered through
  `extensions/adapters/presenters/tui/markdown.fnl` by default and can be toggled with `/markdown`.
  Keep rendering terminal-oriented and lightweight; no CommonMark/browser
  parity or syntax highlighting unless separately scoped.
- **Tests run under busted** with `--loaders=lua,fennel`, which enables
  busted's built-in Fennel loader for the test files. Package and extension
  tests live under `packages/**/tests/` and `extensions/**/tests/`; shared test
  helpers live in the dev/test-only `fen-testing` package as `fen.testing`.
  `scripts/busted-helper.lua` (passed via `--helper`) extends `fennel.path` and
  `fennel.macro-path` with every package `src/` tree so test files can
  `(require :fen.core.llm)` or `(import-macros ... :fen.testing.macros)`
  directly. Important: extend `fennel.path`, NOT `package.path`. If `.fnl`
  paths leak into `package.path`, the Lua searcher finds the file first and
  tries to parse Fennel as Lua.
- **Mock modules in tests via `package.loaded`** before requiring the module
  under test. `packages/core/tests/agent_test.fnl` sets
  `package.loaded["fen.core.llm"]` to a fake before requiring
  `fen.core.agent`, so the agent's `(local llm (require :fen.core.llm))`
  resolves to the fake. Avoids constructor-injection refactors.
- **Launcher is POSIX sh.** No bashisms (`[[`, `${var,,}`, arrays, etc.).
- **Agent has a 16-turn safety cap** in `core/agent.fnl#step` (exposed as
  `agent-mod.SAFETY-CAP`). Bump if a real workflow needs more, don't remove.
- **`make-agent` accepts `:convert-to-llm`** — `(AgentMessage[] → Message[])`.
  Default identity. Lets a caller carry custom AgentMessage extensions in
  `agent.messages` and project them to canonical Messages before the
  provider's `convert-messages` runs.
- **`make-agent` accepts `:provider-options`** — table merged into the
  options passed to the provider's `complete`. `:api-key` and `:max-tokens`
  are auto-injected from the agent record. Use this to plumb things like
  `:thinking-budget` (Anthropic extended thinking) or `:base-url` (custom
  endpoints).


