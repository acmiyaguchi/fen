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
`--denied-tools bash,write` is a comma-separated inverse filter that excludes named tools, fails fast for unknown names, and cannot be combined with `--tools` or `--no-tools`.
`--no-tools` disables the entire tool surface and cannot be combined with `--tools` or `--denied-tools`.
These restrictions are propagated to every child launched through `subagent`: a parent allowlist intersects the child's allowlist, a parent denylist is forwarded or removed from the child's allowlist, and parent `--no-tools` forces child `--no-tools`.
The TUI `/btw` side chat propagates the same restriction: its read-only set (`read,grep,find,ls`) is intersected with the parent allowlist and has the parent denylist subtracted, and a parent `--no-tools` or an empty intersection yields a tool-less side chat (text-only Q&A) rather than one that can still read and grep.
A child can always be narrower than its parent but can never gain a tool the parent lacks, and an empty allowlist intersection is rejected before the child starts.
Configuration and usage failures return 2, provider or runtime failures return 1, and a successful discovery or one-shot run returns 0.

## Argument validation

Fen runs blocking and permission checks before validating a tool call's arguments against its registered schema.
Invalid arguments prevent execution and return a tool error whose `details` includes `{:kind :invalid-arguments}` together with the tool name and field errors.
A malformed registered schema also prevents execution and becomes a structured tool error rather than crashing dispatch.
The validator intentionally implements only Fen's small supported vocabulary; unknown JSON Schema keywords are ignored, so validation is best-effort and constraints such as `additionalProperties` are not enforced.
Each tool registration with unknown schema keywords emits one structured warning through the extension log; those keywords never make the tool permanently uncallable.

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
  Containment is process-group scoped: the command and every ordinary
  descendant that stays in the group are killed, but a descendant that
  deliberately escapes the group (for example by calling `setsid()`) can
  survive the timeout even though the tool reports one.
  Whole-tree containment requires the optional sandbox rather than this helper.
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
- **File mutations are serialized per canonical path.** `edit` and `write`
  hold a process-local FIFO mutex from read through write, so concurrent
  cooperative calls from subagent coroutines using relative, absolute, or
  symlinked spellings cannot interleave their read-modify-write operations.
  Mutex callers must hold at most one file lock at a time; re-entrant
  acquisition raises an error, and v1 otherwise intentionally does not attempt
  deadlock prevention for nested locks.

What's deliberately not ported from pi-mono (per the "balanced" port
decision): `bash` streaming/onUpdate, syntax-highlight cache, image MIME
detection, edit's fuzzy match + diff library, fd/rg backends.

## On-demand tool discovery

`tool_search` searches registered tool names, descriptions, snippets, labels,
and owners.
Matching extension tools are activated for the current agent and become
provider-visible on the next request; activation does not create a second
registry or alter execution ownership.
The complete registry remains available to runtime dispatch, while provider
contexts contain only always-visible and activated descriptors.

### Pinned tools

Selected search-gated tools can be pinned so their schemas appear on the first
request without a preliminary `tool_search`.
Set `pinnedTools` in `~/.config/fen/settings.json` to an array of tool names;
when the key is absent fen pins `todo_write` and `subagent` by default, and an
explicit empty array disables pinning.
Pinning only pre-activates a tool's descriptor for the conversation; it does not
change the tool's registered exposure, and unknown names are ignored.
Each reset conversation (`/new`, resume, handoff) re-applies the pin set.

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
review pass — out of the parent's context.
It is parallel-safe (see "Cooperative execution" below) with a default cap of 4
concurrent children, and `background: true` returns a run id for detached work.
The complete contract — launch and management parameters, routing policy, agent
discovery, run status, steering, budgets, and telemetry — is documented once in
[`extensions.md`](extensions.md) "Subagents".
At runtime, `/docs tools subagent` and `fen_docs` expose the live
provider-facing schema.

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


