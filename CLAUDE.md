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
extensions/session-jsonl/                 Append-only JSONL session backend
packages/core/src/fen/core/settings.fnl             User preferences in
                                                     ~/.config/fen/settings.json
extensions/provider-openai/               OpenAI Chat Completions/Responses provider extension
extensions/provider-openai-codex/         ChatGPT Codex auth/provider extension
extensions/provider-anthropic/            Anthropic Messages provider extension
extensions/builtin-tools/                 Built-in bash/read/write/ls/edit/grep/find
extensions/builtin-commands/              Built-in slash commands
extensions/default-prompt/                Cwd/date/tools/project prompt policy and resource discovery
extensions/skills/                        SKILL.md discovery + ignore engine
extensions/tui/                           Full-screen termbox2 presenter
extensions/mem/                           Runtime memory diagnostics
extensions/agent-state/                   Agent-state inspection tool
extensions/handoff/                       /handoff command extension
packages/fen/src/fen/main.fnl                      CLI entry: arg parse, provider dispatch,
                                                    first-party registration, reload
bin/fen-dev                                        Source-checkout dev wrapper for the single-file runtime
```

Compiled `.lua` for the Nix-built binary lands in package `dist/` trees inside
build sandboxes. Local package `dist/` directories are gitignored — don't check
them in or hand-edit them.

## Workflow

Canonical source-checkout development uses the single-file runtime with source
overlays; no generated Lua tree is needed for normal `.fnl` edit/reload
work:

```sh
nix build .#fen
FEN_BIN=$PWD/result/bin/fen bin/fen-dev
# edit .fnl, then /reload in the running TUI
```

Fast checks while editing:

```sh
nix develop                         # dev shell (gets fennel, busted, lua-cjson, libcurl headers)
fennel scripts/fennel-check.fnl     # lint-check all .fnl files (compile + strict-globals)
make test                           # busted on packages/**/tests/**/*_test.fnl
nix flake check                     # reproducible CI/check surface
```

Nix owns binary assembly; do not use generated `dist/` trees as a dev loop or
release artifact.

`fennel scripts/fennel-check.fnl` compiles every `.fnl` file with `--globals`
locked to standard Lua 5.4 globals (src/) or standard + busted BDD globals
(tests/).
It catches syntax errors, unbalanced delimiters, and unknown identifiers
(typos, missing `local` bindings) without executing any code. Run it after
editing Fennel sources — it's faster than a full build and catches problems
plain Fennel compilation can otherwise miss (bad globals become silent
assignments in compiled Lua).

## Hot reload is the development loop

`/reload` is *the* way to iterate on this codebase. Under the canonical
`.#fen` + `bin/fen-dev` workflow, edit a `.fnl`, type `/reload` from the
running TUI, and keep working on the same session — the embedded Fennel compiler
loads the changed source directly through `--dev-path` / `--extension-root`.
Agents do **not** need to rebuild before telling the user a source change is
ready to hot reload when the user is on `bin/fen-dev`.

Do not rebuild generated Lua before `/reload` when using `bin/fen-dev`.
Restarting loses the TUI transcript, termbox state, the open session file, and
any cached config — it should feel costly. New code is designed under the
constraint "this must work under reload."

### How it works

`packages/fen/src/fen/main.fnl` keeps a `RELOADABLE` list of module names. `/reload`
calls `manual-reload!` for each: clear `package.loaded[modname]`,
re-`require` (re-runs the module body), then **copy the new exports
onto the original module table in place**. A `(local foo (require
:fen.core.foo))` capture keeps the same table reference; the next `foo.bar`
call resolves through the mutated table and lands on the new function.
Module-table lookup is the contract that makes reload work.

### What reloads, what doesn't

Reloadable: every `fen.core.*` module in the list (including
`fen.core.extensions`, the api itself), provider implementation modules under
`fen.extensions.provider_*`, and `fen.util.*` helpers. First-party extension
modules are reloaded by the extension loader from their manifests. Bodies
re-run, exports get re-pointed.

Not reloadable, identity must persist across reload:

- **`fen.extensions.tui.state`** — termbox lifecycle (init flag, dimensions), the
  append-only transcript, scroll position, status counters, view
  toggles. Re-running the body would reset the live terminal.
- **`fen.core.extensions.state`** — the bus subscriber lists, registries
  (tools, commands, presenters, hooks), system-prompt fragments,
  loaded-extension manifests, and the active presenter ui-slot. Reloadable
  `fen.core.extensions.*` behavior modules read and write through this companion
  module, mirroring the `fen.extensions.tui.state` ↔ reloadable TUI behavior split. Editing api,
  dispatch, prompt, presenter, or loader logic reloads cleanly; subscriptions
  and contributions survive because they live in `fen.core.extensions.state`.
- `fen.main` — already on the stack.

### Rules for new code

- **Default to RELOADABLE.** Add the module name to the list in
  `packages/fen/src/fen/main.fnl`. Most code is iteration-prone and benefits.
- **Split state from behavior** when callers outside the module hold
  references that must persist. `fen.extensions.tui.state` ↔ reloadable TUI behavior is the canonical
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

Anything exported from a non-reloadable module (`fen.extensions.tui.state`,
`fen.core.extensions.state`) is shape-stable — its layout is a contract that
callers depend on across reload. Keep those surfaces small; iteration-
prone logic does not belong there. Behavior that *consumes* that state
(`fen.core.extensions.*`, TUI behavior modules) goes in sibling modules that reload against
it, so the state is what's stable, the code is what's editable.

The design choices in `fen.core.extensions` (event bus on the state table,
owner-tagged contributions, `unregister-by-owner`, the
`extensions.dispatch-command` lookup-and-pcall path) fall out of this
split: subscriptions and registries live in `fen.core.extensions.state` and
survive any reload of the api itself. The api factory (`make-api`) wraps
its method references in closures that resolve through the module table
at call time, so an api held past a reload picks up the new behavior
rather than pinning the old.

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

## Provider interface

Each provider module exports a record with at minimum:
`{:api :provider :complete :convert-messages :convert-tools :map-stop-reason
  :parse-response :build-body}`.

Register through the extension API with `api.register :provider` (and
optionally `api.register :auth-backend`). The agent dispatches via
`(llm.complete agent.provider-api model context options)`. Adding another
provider = add or install an extension that registers a provider record.

OpenAI Chat Completions does **not** return thinking content even for
reasoning models (o-series, GPT-5). When that's needed, add a sibling
`provider-openai/openai_responses.fnl` rather than overloading
`openai_completions.fnl`.

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
  with the tiny Lua binding vendored in `extensions/tui/vendor/` and
  built into `extensions/tui/dist/termbox2.so`.
- **Termbox2 lifecycle state lives in
  `extensions/tui/state.fnl`** and bus
  subscriptions / extension registries live in
  `packages/core/src/fen/core/extensions/state.fnl`. Both are excluded from
  `RELOADABLE`; their reloadable siblings read and write through them. See the
  "Hot reload" section above for the full rule.
- **Markdown rendering exists.** Assistant text is rendered through
  `extensions/tui/markdown.fnl` by default and can be toggled with `/markdown`.
  Keep rendering terminal-oriented and lightweight; no CommonMark/browser
  parity or syntax highlighting unless separately scoped.
- **Tests run under busted** with `--loaders=lua,fennel`, which enables
  busted's built-in Fennel loader for the test files. Package-owned tests live
  under `packages/**/tests/`; shared test helpers stay in `tests/support/`.
  `tests/busted-helper.lua` (passed via `--helper`) extends `fennel.path` with
  every package `src/` tree so test files can `(require :fen.core.llm)` etc.
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

## Sessions

Conversations persist as append-only JSONL under
`${XDG_STATE_HOME:-~/.local/state}/fen/sessions/<cwd-slug>/<ISO>_<id>.jsonl`.
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

Saves are wired in `packages/fen/src/fen/main.fnl` as a flush closure that diffs
`agent.messages` length before/after each `step` call. No metatables, no
on-event coupling.

## Custom providers (models.json)

OpenAI-compat HTTP endpoints (Ollama local, Ollama Cloud, vLLM, LM Studio,
proxies) are configured via `~/.config/fen/models.json` — read by
`packages/core/src/fen/core/llm/models.fnl` at first call and cached until `/reload` re-requires
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

Custom provider definitions live in `~/.config/fen/models.json`; persistent user preferences live separately in `~/.config/fen/settings.json`. The latter currently stores `defaultProvider` and `defaultModel` (camelCase on disk, kebab-case internally). CLI `--provider`/`--model` flags win, then settings defaults, then the built-in `openai` fallback. The `/model` command writes settings after a successful switch. Do not put mutable preferences in `models.json`.

The auth header is **omitted entirely** when api-key is nil/empty so
auth-less local servers don't get a stray `Authorization: Bearer ` line.

## Skills

`SKILL.md` files are discovered recursively from the original
fen roots plus pi/Agent Skills-compatible locations:
`${XDG_CONFIG_HOME:-~/.config}/fen/skills`, `.fen/skills`,
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
implementations live under
`extensions/builtin-tools/`. They mirror pi-mono's `bash`,
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
- **Distribution follow-ups** — #62, #63, #64. The single-file Nix binary and
  scratch Docker smoke image have landed; the `lua-curl` rock has been replaced
  with the in-tree `fen_http.so` libcurl binding (#65 closed). Remaining work is
  ARMv7/aarch64 artifact hardening and release automation.
- **Streaming / SSE provider events** — #24. Current HTTP is cooperative via
  `complete-coop` + `util.http`, but providers still aggregate complete
  non-streaming responses before parsing.
- **Codex subscription / OAuth auth** — #23 closed; native PKCE login lives in
  `extensions/provider-openai-codex/openai_codex_login.fnl` (`fen --login
  openai-codex`). The auth-backend record carries `:login!` / `:logout!`
  optional methods that `--login` / `--logout` dispatch through, so future
  providers can register the same hooks. Token refresh is still in
  `openai_codex_oauth.fnl`. Storage in `~/.pi/agent/auth.json` is shared
  with pi-mono.
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
rendering (#11), tool-output fidelity/truncation spill files (#5/#6), and the
initial distribution baseline from #43 (`nix build`, scratch Docker smoke
image).

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

Nix is the canonical reproducible build path. The public runtime artifact is
the production single-file binary.

- `nix build .#fen` builds the single-file binary used by the canonical
  source-checkout dev workflow (`FEN_BIN=$PWD/result/bin/fen bin/fen-dev`) and
  by distribution.
- Cross single-file binaries are exposed from x86_64 Linux as
  `.#fen-linux-aarch64` and `.#fen-linux-armv7-gnueabihf`.
- `nix run .#dockerSmoke` builds/loads a scratch-based Docker image and runs
  `fen --help`; `nix run .#loadDockerDev` loads the same image as `fen:dev`.
  The image uses `/bin/fen` as entrypoint via the copied glibc loader and includes static BusyBox
  applets on `PATH`, `/tmp`, and CA certificates. For Codex smoke tests, mount
  `~/.pi/agent` and set `PI_CODING_AGENT_DIR` inside the container.

The old non-Nix `fen-dist.tar.gz` target, public wrapped Lua package, portable
Nix runtime tarball, and source-checkout `bin/fen` launcher assembled directly
from generated `dist/` trees have been retired. Use `bin/fen-dev` for checkout
development and `nix build .#fen` for the runtime artifact. No release artifact
should be cut from a local generated-tree path.

Open distribution/workflow follow-ups are tracked separately: #63 (release
workflow), #66 (production single-file executable), #68 (extension dependency
builds), and #69 (canonicalize build/dev/distribution workflows).
