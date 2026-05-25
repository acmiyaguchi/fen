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

## Tools

Built-ins are registered by the first-party `builtin_tools` extension and their
implementations live under
`extensions/behaviors/kernel/builtin-tools/`. They mirror pi-mono's `bash`,
`read`, `write`, `ls`, `edit`, `grep`, `find`. POSIX-only stance:

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

## Cooperative execution

Tool executors may receive an optional cooperative yield callback from the agent loop.
Long local work should call it between chunks, scans, pipe reads, and writes so the TUI can repaint and observe cancellation.
The callback may raise to cancel the operation.
Tools that open files, pipes, subprocesses, or spill outputs must close those resources before rethrowing cancellation or other errors.
This callback is an implementation detail of the runtime and is backward-compatible with tools that ignore the extra argument.

The first-party `todo` companion extension separately registers `todo_write`.
It lets the model overwrite a structured session todo list.
It stores the snapshot in the tool-result `details` payload for replay.
It exposes `/todos`, a TUI panel, a status item, and introspection.


