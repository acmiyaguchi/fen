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
                                      (bash/read/write/ls/edit/grep/find)
src/core/session.fnl                  Append-only JSONL transcripts
                                      (open/append/load/latest-for-cwd)
src/core/skills.fnl                   SKILL.md discovery + system-prompt
                                      injection
src/core/models.fnl                   ~/.config/agent-fennel/models.json loader
                                      (custom OpenAI-compat providers — Ollama,
                                      vLLM, LM Studio, etc.)
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

## Sessions

Conversations persist as append-only JSONL under
`${XDG_STATE_HOME:-~/.local/state}/agent-fennel/sessions/<cwd-slug>/<ISO>_<id>.jsonl`.
Line 1 is a `{:type :session :version 1 :id :timestamp :cwd}` header;
subsequent lines are `{:type :message :timestamp :message <canonical-msg>}`.
The `cwd-slug` mirrors pi-mono's `--<encoded-cwd>--` shape (slashes → `-`,
sandwiched in `--`).

Flags:
- `--continue` — replay the latest session for the current cwd before the
  first step.
- `--no-session` — skip persistence entirely.

What we deliberately don't have (vs pi-mono): branching/parentId tree,
fork, compaction summaries, `model_change` / `thinking_level_change`
entries. Forward-compatible: readers should ignore unknown `:type` values.

Saves are wired in `src/main.fnl` as a flush closure that diffs
`agent.messages` length before/after each `step` call. No metatables, no
on-event coupling.

## Custom providers (models.json)

OpenAI-compat HTTP endpoints (Ollama local, Ollama Cloud, vLLM, LM Studio,
proxies) are configured via `~/.config/agent-fennel/models.json` — read by
`src/core/models.fnl` at first call and cached until `/reload` re-requires
the module. Mirrors the floor of pi-mono's `models.json` schema (see
`pi-mono/packages/coding-agent/docs/models.md`).

Field handling:
- `apiKey` is resolved via a heuristic: UPPER\_SNAKE\_CASE values → `os.getenv`,
  anything else → literal. **No `!shell-cmd` support.**
- `baseUrl` may be either the v1 root (`http://localhost:11434/v1`) or the
  full POST endpoint — `openai_completions.build-url` appends
  `/chat/completions` only when the path doesn't already end in it.
- `compat` is passed verbatim into `provider-options` and consumed by
  `build-body`. Today only `compat.maxTokensField` is honored (Ollama needs
  `"max_tokens"`); other keys are accepted forward-compatibly.

Deliberately skipped vs pi-mono: `!shell-cmd`, `modelOverrides`, per-model
`compat`, cost/pricing fields, image input declarations, the `/model`
slash command. Reload via `/reload`, not a dedicated config-only command.

The auth header is **omitted entirely** when api-key is nil/empty so
auth-less local servers don't get a stray `Authorization: Bearer ` line.

## Skills

`SKILL.md` files are discovered in:
1. `${XDG_CONFIG_HOME:-~/.config}/agent-fennel/skills/<name>/SKILL.md` (user)
2. `./.agent-fennel/skills/<name>/SKILL.md` (project)
3. Any `--skills <dir>` extras (cli scope).

Frontmatter is minimal YAML — only `name` and `description` are read. We
don't recurse past a SKILL.md root and we don't honor
`disable-model-invocation`. Discovered skills are listed in the system
prompt with their absolute paths; the model uses the existing `read` tool
to load the body on demand.

## Tools

Built-ins live in `src/core/tools.fnl` and mirror pi-mono's `bash`,
`read`, `write`, `ls`, `edit`, `grep`, `find`. POSIX-only stance:

- **`grep`/`find` shell out to system `grep(1)`/`find(1)`.** No `rg`/
  `fd` dependency, no `.gitignore` awareness. Path/pattern/glob inputs
  pass through `shellquote`.
- **`read` has no image base64 and no syntax highlighting.** Optional
  `offset`/`limit` slice file lines (1-indexed); default is full slurp.
- **`edit` is exact-match only.** No fuzzy fallback, no unified-diff
  output. Each `old_string` must occur exactly once in the original
  file; multiple disjoint edits per call are validated for overlap and
  applied to the original snapshot, not sequentially. Algorithm in
  `validate-edits` / `apply-edits`.
- **`write` does `mkdir -p` on the parent dir** so the model doesn't
  need a separate `bash` call for nested paths.
- **`bash` accepts a `timeout` (seconds)** — wraps the command in
  `timeout(1)`, which exits 124 on kill.
- **`bash` merges stderr into stdout (`2>&1`).** Intentional simplification
  vs pi-mono's separate-stream tagging. Pipe `2>/dev/null` inside the cmd
  if you want to drop one stream.
- **`bash` accepts an optional `cwd`** — validated to exist, then
  prefixed as `cd <quoted> && <cmd>`. With a timeout, the whole thing
  is wrapped in `sh -c` so the timeout applies to the inner command,
  not just `cd`.
- **`edit` is exact-byte match — no CRLF normalization.** A file with
  `\r\n` line endings will not match an `old_string` that uses `\n`.
  Validate-edits surfaces a "file has CRLF, old_string uses LF — try
  \r\n" hint when this happens, so the failure is named rather than
  silent. Auto-normalization while preserving original line endings on
  write needs careful index tracking; deferred.

What's deliberately not ported from pi-mono (per the "balanced" port
decision): file-mutation queue, `bash` streaming/onUpdate, signal
abort, syntax-highlight cache, image MIME detection, edit's fuzzy
match + diff library, fd/rg backends.

## Out of scope (don't add unless asked)

Streaming SSE, OAuth, image input, markdown rendering, model-pricing
registry, abort signals, parallel/sequential tool execution mode. The
original plan in
`/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` lists
the v0 boundary; sessions, skills, and the full pi-mono tool surface
(as scoped under "Tools" below) are now in.

## Distribution shape

`make dist` tarballs `dist/` + `bin/` + `README.md`. End user needs `lua5.4`
+ `lua-curl` + `lua-cjson` on the target. The launcher prepends a local
`lua_modules/` tree to `LUA_PATH`/`LUA_CPATH`, so users can ship rocks
alongside the launcher when system rocks aren't available.
