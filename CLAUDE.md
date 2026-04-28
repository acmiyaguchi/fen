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
src/core/llm/init.fnl                 Provider registry / dispatcher
                                      (mirrors pi-mono api-registry.ts)
src/core/llm/models.fnl               ~/.config/agent-fennel/models.json loader
                                      (custom OpenAI-compat providers — Ollama,
                                      vLLM, LM Studio, etc.)
src/core/llm/event_stream.fnl         Provider streaming event accumulator
src/core/agent.fnl                    Agent loop on canonical messages
src/core/tools.fnl                    AgentTool executor/helpers
src/extensions/builtin_tools/*.fnl    Built-in tool registry, implementations, shared helpers
                                      (bash/read/write/ls/edit/grep/find,
                                      truncate, util)
src/extensions/builtin_commands/*.fnl Built-in slash command extension
                                      (/new/status/reload/queue/cancel-all/help)
src/core/prompt/init.fnl              System-prompt assembly: cwd/date/tools,
                                      project context, skills, guidelines
src/core/prompt/resources.fnl         Project/user prompt resource loader
                                      (AGENTS.md/CLAUDE.md/SYSTEM overlays)
src/core/prompt/skills.fnl            SKILL.md discovery + system-prompt
                                      injection
src/core/extensions/init.fnl          Small extension-facing API facade / make-api
src/extensions/builtin_tools/init.fnl First-party extension registering built-in tools
src/core/extensions/*.fnl             Split extension runtime: persistent state,
                                      events, registry, commands, prompt,
                                      presenter, introspection, loader, test_api
src/core/session.fnl                  Append-only JSONL transcripts
                                      (open/append/load/latest-for-cwd)
src/providers/openai_completions.fnl  OpenAI Chat Completions provider
src/providers/anthropic_messages.fnl  Anthropic Messages provider
src/extensions/tui/init.fnl           Full-screen termbox2 presenter extension
src/extensions/tui/state.fnl          Persistent mutable TUI state across
                                      /reload (termbox lifecycle, transcript)
src/extensions/tui/markdown.fnl       Lightweight TUI Markdown renderer
src/util/http.fnl                     curl-multi cooperative HTTP helper
src/util/process.fnl                  Cooperative pipe-drain helper for bash
src/util/json.fnl                     lua-cjson wrapper
src/util/log.fnl                      Leveled stderr logger (AGENT_FENNEL_LOG)
src/util/path.fnl                     POSIX path/XDG helpers (shell-quote,
                                      dirname/basename, file-/dir-exists?,
                                      ancestors-root-to-leaf, config/state-dir)
bin/agent-fennel                      POSIX-sh launcher
```

Compiled `.lua` lands in `dist/` mirroring `src/` layout. `dist/` is
gitignored — don't check it in.

## Workflow

```sh
nix develop                # dev shell (gets fennel, busted, lua-curl, lua-cjson)
make fennel-check          # lint-check all .fnl files (compile + strict-globals)
make build                 # fennel --compile src/**/*.fnl → dist/
make test                  # busted on tests/*_test.fnl
bin/agent-fennel --help    # launcher smoke check
```

Edit `.fnl` only; never hand-edit `dist/*.lua`. Rebuild after every Fennel
change before running.

`make fennel-check` compiles every `.fnl` file with `--globals` locked to
standard Lua 5.4 globals (src/) or standard + busted BDD globals (tests/).
It catches syntax errors, unbalanced delimiters, and unknown identifiers
(typos, missing `local` bindings) without executing any code. Run it after
editing Fennel sources — it's faster than a full build and catches problems
`make build` silently ignores (bad globals become silent assignments in
compiled Lua).

## Hot reload is the development loop

`/reload` is *the* way to iterate on this codebase. Edit a `.fnl`, run
`make build`, type `/reload` from the running TUI, keep working on the
same session. Restarting loses the TUI transcript, termbox state, the
open session file, and any cached config — it should feel costly. New
code is designed under the constraint "this must work under reload."

### How it works

`src/main.fnl` keeps a `RELOADABLE` list of module names. `/reload`
calls `manual-reload!` for each: clear `package.loaded[modname]`,
re-`require` (re-runs the module body), then **copy the new exports
onto the original module table in place**. A `(local foo (require
:core.foo))` capture keeps the same table reference; the next `foo.bar`
call resolves through the mutated table and lands on the new function.
Module-table lookup is the contract that makes reload work.

### What reloads, what doesn't

Reloadable: every `core.*` module in the list (including
`core.extensions`, the api itself), all `providers.*`, `tui.tui` /
`tui.markdown`, and the `util.*` helpers. Bodies re-run, exports get
re-pointed.

Not reloadable, identity must persist across reload:

- **`tui.state`** — termbox lifecycle (init flag, dimensions), the
  append-only transcript, scroll position, status counters, view
  toggles. Re-running the body would reset the live terminal.
- **`core.extensions.state`** — the bus subscriber lists, registries
  (tools, commands, presenters, hooks), system-prompt fragments,
  loaded-extension manifests, and the active presenter ui-slot. Reloadable
  `core.extensions.*` behavior modules read and write through this companion
  module, mirroring the `tui.state` ↔ `tui.tui` split. Editing api,
  dispatch, prompt, presenter, or loader logic reloads cleanly; subscriptions
  and contributions survive because they live in `core.extensions.state`.
- `main.fnl` — already on the stack.

### Rules for new code

- **Default to RELOADABLE.** Add the module name to the list in
  `main.fnl`. Most code is iteration-prone and benefits.
- **Split state from behavior** when callers outside the module hold
  references that must persist. `tui.state` ↔ `tui.tui` is the canonical
  example: state lives in a non-reloadable module, rendering code in a
  sibling that reloads against it.
- **Cross-module wiring resolves at call time, not capture time.** Use
  `module.fn` lookups (reload-safe), not `(local fn module.fn)` captured
  into long-lived state (pinned to the old function for the rest of the
  process).
- **Reload-side-effects must be idempotent.** Modules in RELOADABLE that
  register things (commands, tools, fragments, event handlers) clear
  their prior registrations before re-registering, or every reload
  doubles them. `extensions.builtin_commands` does this with
  `(extensions.unregister-by-owner :builtin_commands)` at the top of its body. The
  future external-extension loader will follow the same pattern per
  extension.

### Why this shapes the api

Anything exported from a non-reloadable module (`tui.state`,
`core.extensions.state`) is shape-stable — its layout is a contract that
callers depend on across reload. Keep those surfaces small; iteration-
prone logic does not belong there. Behavior that *consumes* that state
(`core.extensions.*`, `tui.tui`) goes in sibling modules that reload against
it, so the state is what's stable, the code is what's editable.

The design choices in `core.extensions` (event bus on the state table,
owner-tagged contributions, `unregister-by-owner`, the
`extensions.dispatch-command` lookup-and-pcall path) fall out of this
split: subscriptions and registries live in `core.extensions.state` and
survive any reload of the api itself. The api factory (`make-api`) wraps
its method references in closures that resolve through the module table
at call time, so an api held past a reload picks up the new behavior
rather than pinning the old.

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

Register in `src/core/llm/init.fnl`. The agent dispatches via
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
  Lua 5.4 rock, forces a 5.2 toolchain. The TUI is intentionally termbox2,
  with the tiny Lua binding vendored in `vendor/` and built into
  `dist/termbox2.so`.
- **Termbox2 lifecycle state lives in `src/extensions/tui/state.fnl`** and bus
  subscriptions / extension registries live in
  `src/core/extensions/state.fnl`. Both are excluded from `RELOADABLE`;
  their reloadable siblings (`extensions.tui`, `core.extensions.*`) read and
  write through them. See the "Hot reload" section above for the full
  rule.
- **Markdown rendering exists.** Assistant text is rendered through
  `src/extensions/tui/markdown.fnl` by default and can be toggled with `/markdown`.
  Keep rendering terminal-oriented and lightweight; no CommonMark/browser
  parity or syntax highlighting unless separately scoped.
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
`src/core/llm/models.fnl` at first call and cached until `/reload` re-requires
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

`SKILL.md` files are discovered recursively from the original
agent-fennel roots plus pi/Agent Skills-compatible locations:
`${XDG_CONFIG_HOME:-~/.config}/agent-fennel/skills`, `.agent-fennel/skills`,
`~/.pi/agent/skills`, `~/.agents/skills`, project `.pi/skills`, ancestor
`.agents/skills`, and common Claude/Codex skill roots. Discovery skips dotdirs,
`node_modules`, and paths matched by `.gitignore`, `.ignore`, or `.fdignore`.
Explicit paths can be passed via `--skill <path>`; `--skills <dir>` remains a
compatibility alias.

Frontmatter is minimal YAML. `description` is required; `name` is optional
and falls back to the skill directory/file name. `disable-model-invocation:
true` skills are discovered but omitted from the system prompt. Discovered
skills are listed in an Agent Skills-style XML block with absolute paths; the
model uses the existing `read` tool to load the body on demand.

## Tools

Built-ins are registered by the first-party `builtin_tools` extension and their
implementations live under `src/extensions/builtin_tools/`. They mirror pi-mono's `bash`,
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
decision): file-mutation queue, `bash` streaming/onUpdate, full
process-group abort/signal plumbing (narrow bash kill-on-cancel is #9),
syntax-highlight cache, image MIME detection, edit's fuzzy match + diff
library, fd/rg backends.

## Roadmap and scope

The old v0 "out of scope" list has been split into issue-tracked work vs.
still-intentional omissions. If an item has an open issue, follow that plan
instead of treating this file as a veto.

Tracked / no longer blanket out-of-scope:
- **Streaming / SSE provider events** — #24. Current HTTP is cooperative via
  `complete-coop` + `util.http`, but providers still aggregate complete
  non-streaming responses before parsing.
- **Codex subscription / OAuth auth** — #23. Keep token storage/refresh and
  Codex Responses provider work behind that issue; do not ad-hoc token hacks.
- **Bash cancel semantics** — #9. TUI cancel is cooperative today, but killing
  a silent long-running child before `pclose()` blocks is still pending.
- **Tool batching / multi-tool turns** — #26 and #27. Read/edit batch shapes
  and explicit parallel tool-use prompting are planned; true concurrent tool
  execution inside one turn remains a separate, not-yet-scoped change.
- **Extension and sandbox work** — #15 and #19. Sandbox policy belongs in an
  opt-in extension, not core tool implementations.
- **Interactive model/session UX** — #14 and #10. Model switching and richer
  session management are planned additively.
- **Introspection/dev helpers** — #20, #21, #22. REPL, `agent_state`, and
  status version info are tracked.

Already landed from that old list/roadmap: termbox2 full-screen TUI (#1),
cooperative TUI/HTTP responsiveness (#2), custom providers (#8), project
context/skills (#13), system-prompt resource assembly (#17), Markdown TUI
rendering (#11), and tool-output fidelity/truncation spill files (#5/#6).

Still intentionally out of scope unless a new issue asks for it: image input
and image MIME/base64 handling, full model-pricing/cost registry, full
CommonMark/browser-style rendering, code syntax highlighting, fd/rg hard
runtime dependencies, and wholesale pi-mono feature parity.

The original plan in
`/home/anthony/.claude/plans/in-agent-fennel-i-want-wise-iverson.md` lists
the v0 boundary; sessions, skills, the termbox2 TUI, Markdown rendering,
custom providers, and the full pi-mono tool surface (as scoped under
"Tools" below) are now in.

## Distribution shape

`make dist` tarballs `dist/` + `bin/` + `README.md`. End user needs `lua5.4`
+ `lua-curl` + `lua-cjson` on the target. The launcher prepends a local
`lua_modules/` tree to `LUA_PATH`/`LUA_CPATH`, so users can ship rocks
alongside the launcher when system rocks aren't available.
