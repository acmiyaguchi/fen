# Built-in tools

Contracts and implementation notes for the first-party tool surface.

## TUI rendering

The TUI keeps tool-heavy transcripts compact by rendering built-in tool calls as short status rows, for example `tool> run read README.md:1-20` or `tool> run $ make test`.
When the result arrives, the call/result pair folds into a single console-friendly row such as `tool> ok  read README.md (42 lines, 3.1KB)` or `tool> err read missing.txt (1 line, 24B)`.
Use `/expand` or `ctrl-o` in the TUI to toggle expanded tool-result body previews under the paired summary row.
Expanded previews are capped by the presenter preview limit so very large outputs do not flood the transcript.

## Tool-result sanitation

Fen sanitizes provider-visible tool-result text before new results are emitted and stored in the JSONL transcript; those sanitized stored results are then safe to replay to later provider calls.
Raw NUL bytes, invalid UTF-8 bytes, and control bytes other than tab/newline/carriage-return are escaped as visible ASCII such as `\\x00`.
Each text block in a tool result is also capped by bytes (`FEN_TOOL_RESULT_MAX_BYTES`, default 65536), and Fen appends an explicit marker when output was sanitized or truncated.
This is a final safety net against provider 400s and wedged sessions; tools should still summarize or truncate domain-specific output themselves when possible.
The sanitizer preserves the required one-result-per-tool-call pairing rather than dropping unsafe results.
Structured `details` payloads are preserved for presenters/replay and are not sent to providers.
Already-written legacy sessions are repaired separately at provider replay/session-doctor boundaries.

## CLI discovery and one-shot policy

Use the live registry rather than hardcoding available capabilities in scripts.

```sh
fen list --json              # discover surfaces first
fen list tools --json
fen list models --provider sakana --json
fen list models --all --json      # one merged catalog across available providers
fen show command goal --json
```

`list` supports `commands`, `tools`, `providers`, `models`, `presenters`, `session-backends`, `extensions`, `skills`, and `agents`.
`show` accepts the same surface and an entry name.
Both commands load the normal extension registry but do not open a presenter, create a session, or contact an LLM.
Provider discovery reports secret-free authentication availability and never emits credentials.
`list models` may contact selected providers when they have dynamic model catalogs.
`list models --all` merges the catalogs of every provider with `available? true` into a single result, tagging each row with its `provider` and canonical `provider/id`; providers whose dynamic catalog fetch fails fall back to static/default entries and report `catalog-status` per row.
`--all` keeps discovery session-free and LLM-free like the rest of `list`, and cannot be combined with `--provider`.
Use a canonical `provider/id` with `show model` when the same model ID exists under multiple providers.
Pass `--extension PATH` to include an explicit extension in discovery.

One-shot prompts can be supplied without shell interpolation through stdin or a file.

```sh
git diff | fen --print - --no-session
fen --prompt-file review.txt --presenter json --no-session
```

`--tools read,grep,find,ls` is a hard runtime allowlist: excluded tools are neither advertised to the provider nor executable by the agent.
`--no-tools` disables the entire tool surface and cannot be combined with `--tools`.
Configuration and usage failures return 2, provider or runtime failures return 1, and a successful discovery or one-shot run returns 0.

## Tools

Built-ins are registered by the first-party `builtin_tools` extension and their
implementations live under
`extensions/behaviors/kernel/builtin-tools/`.
The seven workspace tools (`bash`, `read`, `write`, `ls`, `edit`, `grep`, and
`find`), `tool_search`, and `fen_docs` are sent to providers by default.
A CLI allowlist can narrow this set for one-shot runs.
Other registered extension tools remain executable but their schemas are sent
only after `tool_search` activates them for the current conversation.
They mirror pi-mono's workspace tools with this POSIX-only stance:

- **`grep`/`find` shell out to system `grep(1)`/`find(1)`.** No `rg`/
  `fd` dependency, no `.gitignore` awareness. Path/pattern/glob inputs
  pass through `shellquote`.
- **`read` has no image base64 and no syntax highlighting.** Optional
  `offset`/`limit` slice file lines (1-indexed); default is full slurp.
  Prefer the batch shape `paths` when several independent files are known up
  front; entries may be path strings or `{path, offset, limit}` objects.
- **`edit` is exact-match only.** No fuzzy fallback, no unified-diff
  output. Each `old_string` must occur exactly once in the original
  file; multiple disjoint edits per call are validated for overlap and
  applied to the original snapshot, not sequentially. Algorithm in
  `validate-edits` / `apply-edits`. Batch all known non-overlapping edits:
  same-file replacements belong in one `edits` array, and multi-file
  replacements belong in the `files` shape. Batch validation is all-or-nothing
  before mutation.
- **`write` does `mkdir -p` on the parent dir** so the model doesn't
  need a separate `bash` call for nested paths.
- **`bash` accepts a `timeout` (seconds)** — fen enforces the wall-clock
  deadline through its internal process helper, terminates the command's
  process group, and reports a timeout marker instead of relying on external
  `timeout(1)`.
- **`bash` merges stderr into stdout (`2>&1`).** Intentional simplification
  vs pi-mono's separate-stream tagging. Pipe `2>/dev/null` inside the cmd
  if you want to drop one stream.
- **`bash` accepts an optional `cwd`** — validated to exist, then passed to
  the process helper as the command working directory.
  With a timeout, the same child process group is supervised regardless of `cwd`.
- **`edit` is exact-byte match — no CRLF normalization.** A file with
  `\r\n` line endings will not match an `old_string` that uses `\n`.
  Validate-edits surfaces a "file has CRLF, old_string uses LF — try
  \r\n" hint when this happens, so the failure is named rather than
  silent. Auto-normalization while preserving original line endings on
  write needs careful index tracking; deferred.
- **Same-turn edits to the same file must be batched.** The agent loop detects
  multiple `edit` tool calls in one assistant turn that target the same path,
  rejects those calls with matching tool-result errors, and asks the model to
  retry as one batched edit. This preserves the provider-required one
  `tool_result` per `tool_call` shape while avoiding sequential mutation
  against changing file snapshots.

What's deliberately not ported from pi-mono (per the "balanced" port
decision): file-mutation queue, `bash` streaming/onUpdate,
syntax-highlight cache, image MIME detection, edit's fuzzy match + diff
library, fd/rg backends.

## On-demand tool discovery

`tool_search` searches registered tool names, descriptions, snippets, labels,
and owners.
Matching extension tools are activated for the current agent and become
provider-visible on the next request; activation does not create a second
registry or alter execution ownership.
The complete registry remains available to runtime dispatch, while provider
contexts contain only always-visible and activated descriptors.

## Extension-contributed tools

Some tools are not core built-ins; they are registered by first-party
extensions rather than the `builtin_tools` kernel. The `agent_state` and
`fen_docs` tools below are read-only, so they are also on the plan companion's
read-only allowlist (see [`extensions.md`](extensions.md) "Plan companion").
The `subagent` tool is not read-only: it spawns a child agent that can run its
own tools, so it is not on the plan-mode allowlist.

The `goal`, `plan`, `simplify`, `queue`, and `extension` domain tools are
search-exposed rather than always visible.
They call the same domain operations as their slash-command counterparts; they
do not dispatch command strings.
Turn-starting operations use the existing follow-up queue when called from an
active agent turn, so no second deferred-work mechanism is involved.
The `plan` tool deliberately exposes draft, revise, show, and cancel only: plan
approval remains a user slash-command action.
The agent-facing `queue` tool is read-only so it cannot erase user-authored
steering or follow-up input; queue mutation remains an explicit slash-command
action.
Extension reload requires an interactive run state and uses the same
message-preserving agent rebuild pattern as the general `reload` tool.

### `agent_state`

Registered by the `agent-state` companion
(`extensions/behaviors/companions/agent-state/init.fnl`); the query engine lives
beside it in `fen.extensions.agent_state.tool`. It reads structured state of the
running agent and is strictly read-only — it inspects, it does not evaluate code.

- **`query`** (required) — a tiny Fennel-shaped data language over the agent's
  state tree. Operators: `:get`, `:keys`, `:count`, `:pluck`, `:where`,
  `:slice`, `:first`, `:last`. Examples: `(:get :model)`, `(:get :messages -1)`,
  `(:pluck (:get :tools) :name)`, `(:last (:where (:get :messages) :role :assistant))`.
  Prefer narrow queries over dumping large roots.
- **`format`** (optional) — `json` (default) or `fennel`.
- **`max_bytes`** (optional) — output truncation cap; defaults to 8192.

### `fen_docs`

Registered by the docs kernel extension
(`extensions/behaviors/kernel/docs/init.fnl`); it shares its backing registries
with the `/docs` command and the docs browser panel. It reads or searches the
fen runtime docs and extension contracts — register kinds, canonical types,
event shapes, and the live command/tool/provider registries — and is aimed at
authoring extensions.

- **`topic`** (optional) — a docs topic such as `commands`, `tools`,
  `providers`, `types`, `register-kinds`, `events`, or `interfaces`. Use
  `topics` to list them, or `search` to search across all topics.
- **`name`** (optional) — a specific entry within the topic, e.g.
  `{topic:'register-kinds', name:'tool'}`; for `topic='search'`, the query string.
- **`query`** (optional) — a search string, searching all docs or only the
  given `topic` when one is set.
- **`format`** (optional) — `text` (default) or `json`.

No parameter is required; a bare call lists the available topics.

### `subagent`

Registered by the `subagent` companion
(`extensions/behaviors/companions/subagent/init.fnl`). It delegates a focused
task to a **child `fen` process** with its own context window and system
prompt, then returns the child's final text (or actionable diagnostics) to the
parent. Use it to keep long or self-contained work — research, a scoped edit, a
review pass — out of the parent's context. Full behavior, routing policy, agent
discovery, run status, steering, and cancellation are documented in
[`extensions.md`](extensions.md) "Subagents"; the tool contract is summarized
here. At runtime, `/docs tools subagent` and `fen_docs` expose the same
provider-facing schema.

For launch calls, provide **either** a named `agent` **or** an inline `prompt`, plus a `task`.
When both `agent` and `prompt` are given, the named `agent` wins.
Management calls instead set `action` and do not launch a child.

- **`action`** (optional) — manage runs with `list`, `show`, `wait`, `steer`, `cancel`, `cancel-all`, `remove`, `retry`, `clear`, or `reset`.
  Management results include structured `details` so callers do not need to parse the rendered text.
  `clear` rejects while work is active; `reset` explicitly cancels detached work and clears history.
- **`run-id`** — required by `show`, `wait`, `steer`, `cancel`, `remove`, and `retry`.
  It is the stable id returned by a background launch or `list`.
- **`note`** — steering context required by `steer`.
- **`timeout-seconds`** — for `wait`, the cooperative polling budget, defaulting to 30 seconds.
- **`task`** (required for launch) — the work handed to the child agent, delivered as its
  first user message. This is *what to do*, distinct from `prompt`/`agent`
  which define *who the child is*.
- **`agent`** (required unless `prompt` is set) — name of a discovered agent
  definition (the `.md` filename without extension). Discovered from
  `./.fen/agents/`, the user agents directory, and bundled defaults
  (`scout`, `reviewer`, `planner`). Run `/agents` to list them.
- **`prompt`** (required unless `agent` is set) — an inline system prompt used
  directly as the child's persona, so no agent file is needed. Best for one-off
  delegations not worth a reusable file.
- **`cwd`** (optional) — working directory for the child; validated to exist.
  Defaults to the parent's current directory. The child's tool calls run
  relative to this directory.
- **`model`** (optional) — override the child model. Defaults to the agent
  frontmatter value, else the inherited parent model.
- **`provider`** (optional) — override the child provider. A provider-only
  override intentionally omits the inherited model, so the child resolves that
  provider's default model.
- **`timeout-seconds`** (optional) — override the child timeout. Defaults to
  the agent frontmatter value, else 300.

Named `agent` and inline `prompt` follow the same routing/timeout policy: the
inline `model`/`provider`/`timeout-seconds` args behave exactly like the
equivalent agent frontmatter fields. Prefer a named `agent` for reviewable,
reusable policy; use an inline `prompt` for quick one-offs.

Examples:

```fennel
;; named agent
(subagent {:agent "scout"
           :task "what files define the provider interface?"
           :cwd "."})

;; inline prompt, no agent file required
(subagent {:prompt "You are a one-off reviewer. Answer briefly and stop."
           :task "summarize the risk in the current diff"
           :model "claude-haiku-4-5"
           :timeout-seconds 120})
```

The tool is parallel-safe (see "Cooperative execution" below), so several
`subagent` calls in one assistant turn may run concurrently, capped at 4.
Calls are still blocking from the model's perspective: results are collected
when each child exits.
Set `background: true` to return a run id immediately; the TUI pumps detached children cooperatively.
The main agent can subsequently inspect or control them without asking the user to run a slash command:

```fennel
(subagent {:action "list"})
(subagent {:action "show" :run-id "subagent-3"})
(subagent {:action "wait" :run-id "subagent-3" :timeout-seconds 30})
(subagent {:action "steer" :run-id "subagent-3" :note "focus on tests"})
(subagent {:action "cancel" :run-id "subagent-3"})
(subagent {:action "retry" :run-id "subagent-3"})
(subagent {:action "remove" :run-id "subagent-3"})
(subagent {:action "cancel-all"})
(subagent {:action "clear"})
(subagent {:action "reset"})
```

`/new` is a hard conversation boundary: it cancels and reaps detached children, clears stored run history, and removes their TUI tabs.

## Cooperative execution

Tool executors may receive an optional cooperative yield callback from the agent loop.
Long local work should call it between chunks, scans, pipe reads, and writes so the TUI can repaint and observe cancellation.
The callback may raise to cancel the operation.
Tools that open files, pipes, subprocesses, or spill outputs must close those resources before rethrowing cancellation or other errors.
This callback is an implementation detail of the runtime and is backward-compatible with tools that ignore the extra argument.

Tools may also opt in to internal parallel dispatch with `:parallel-safe? true` and an optional `:parallel-cap`.
These fields are not provider-visible tool schema; descriptors omit them before provider calls.
Only tools whose executions do not share mutable Lua state or mutate the same resources should opt in.
The first-party `subagent` companion is parallel-safe because each call supervises an isolated child `fen` process, and it defaults to a cap of 4 concurrent children per consecutive batch.
All non-opted-in tools, including file mutation tools, continue to run serially.

The first-party `todo` companion extension separately registers `todo_write`.
It lets the model overwrite a structured session todo list.
It stores the snapshot in the tool-result `details` payload for replay.
It exposes `/todos`, a TUI panel, a status item, and introspection.


