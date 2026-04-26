# CLAUDE.md

Project-specific notes for Claude Code sessions in this repo. See `README.md`
for end-user docs.

## What this is

A small AI coding-agent CLI written in Fennel, compiled to Lua. Mirrors
pi-mono's interface shapes (canonical Message types, provider abstraction,
agent loop) in vastly simplified form. Targets Lua 5.4 on ARMv7 (Raspberry
Pi-class hardware).

## Module map

```
src/main.fnl                          CLI entry: arg parse, --provider dispatch
src/core/types.fnl                    Canonical Message/Tool/StopReason +
                                      constructors. Doc-heavy reference.
src/core/llm.fnl                      Provider registry / dispatcher
                                      (mirrors pi-mono api-registry.ts)
src/core/agent.fnl                    Agent loop on canonical messages
src/core/tools.fnl                    AgentTool list + built-ins
                                      (bash/read/write/ls)
src/providers/openai_completions.fnl  OpenAI Chat Completions provider
src/providers/anthropic_messages.fnl  Anthropic Messages provider
src/tui/tui.fnl                       ANSI escapes + stty raw -echo
src/util/json.fnl                     lua-cjson wrapper
src/util/log.fnl                      Leveled stderr logger (AGENT_FENNEL_LOG)
bin/agent-fennel                      POSIX-sh launcher
```

Compiled `.lua` lands in `dist/` mirroring `src/` layout. `dist/` is
gitignored — don't check it in.

## Workflow

```sh
nix develop                # dev shell (gets fennel, busted, lua-curl, lua-cjson)
make build                 # fennel --compile src/**/*.fnl → dist/
make test                  # busted on tests/*_test.fnl
bin/agent-fennel --help    # launcher smoke check
```

Edit `.fnl` only; never hand-edit `dist/*.lua`. Rebuild after every Fennel
change before running.

## Canonical types (the contract)

All agent-side code operates on canonical message/tool shapes defined in
`src/core/types.fnl`. Providers convert to/from wire shape on the boundary;
the agent loop never sees provider-specific JSON.

Field naming: kebab-case in Fennel (`:tool-call-id`, `:stop-reason`,
`:is-error?`); semantically identical to pi-mono's camelCase. Wire shapes
stay snake_case (they're going through JSON over HTTP).

Skipped vs pi-mono (additive when needed): ImageContent, response-id /
textSignature / thoughtSignature, usage.cost, executionMode / signal /
onUpdate on tools, prepareArguments / TypeBox schema validation. We DO
include ThinkingContent — both Anthropic extended thinking and OpenAI
reasoning models surface it.

## Provider interface

Each provider module exports a record with at minimum:
`{:api :provider :complete :convert-messages :convert-tools :map-stop-reason
  :parse-response :build-body}`.

Register in `src/core/llm.fnl`. The agent dispatches via
`(llm.complete agent.provider-api model context options)`. Adding a third
provider = new `src/providers/foo.fnl` + one `(register …)` call.

OpenAI Chat Completions does **not** return thinking content even for
reasoning models (o-series, GPT-5). When that's needed, add a sibling
`providers/openai_responses.fnl` rather than overloading
`openai_completions.fnl`.

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
- **lua-curl module name is `cURL`** (capital U/R/L) even though the rock is
  `lua-curl`. lua-cjson is `cjson`.
- **Don't reintroduce lcurses.** Caps at Lua `<5.4`, isn't in nixpkgs as a
  Lua 5.4 rock, forces a 5.2 toolchain. The TUI is intentionally ANSI+stty.
- **Raw mode breaks `\n`.** When the TUI is active `tui.fnl` uses CRLF.
  Keep doing that for any new TUI output.
- **Tests run under busted** with `--loaders=lua,fennel`, which enables
  busted's built-in Fennel loader for the test files. `tests/busted-helper.lua`
  (passed via `--helper`) extends `fennel.path` with `src/` so test files can
  `(require :core.llm)` etc. directly. Important: extend `fennel.path`, NOT
  `package.path`. If `.fnl` paths leak into `package.path`, the Lua searcher
  finds the file first and tries to parse Fennel as Lua.
- **Mock modules in tests via `package.loaded`** before requiring the module
  under test. `tests/agent_test.fnl` sets `package.loaded["core.llm"]` to a
  fake before requiring `core.agent`, so the agent's `(local llm (require
  :core.llm))` resolves to the fake. Avoids constructor-injection refactors.
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

## Out of scope (don't add unless asked)

Streaming SSE, OAuth, image input, session persistence, edit/grep/find
tools, markdown rendering, model-pricing registry, abort signals,
parallel/sequential tool execution mode. The original plan in
`/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` lists
the boundary in full.

## Distribution shape

`make dist` tarballs `dist/` + `bin/` + `README.md`. End user needs `lua5.4`
+ `lua-curl` + `lua-cjson` on the target. The launcher prepends a local
`lua_modules/` tree to `LUA_PATH`/`LUA_CPATH`, so users can ship rocks
alongside the launcher when system rocks aren't available.
