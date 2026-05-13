# Built-in tools

Contracts and implementation notes for the first-party tool surface.

## TUI rendering

The TUI keeps tool-heavy transcripts compact by rendering built-in tool calls as short status rows, for example `tool> run read README.md:1-20` or `tool> run $ make test`.
When the result arrives, the call/result pair folds into a single console-friendly row such as `tool> ok  read README.md (42 lines, 3.1KB)` or `tool> err read missing.txt (1 line, 24B)`.
Use `/expand` or `ctrl-o` in the TUI to toggle expanded tool-result body previews under the paired summary row.
Expanded previews are capped by the presenter preview limit so very large outputs do not flood the transcript.

## Tools

Built-ins are registered by the first-party `builtin_tools` extension and their
implementations live under
`extensions/behaviors/kernel/builtin-tools/`. They mirror pi-mono's `bash`,
`read`, `write`, `ls`, `edit`, `grep`, `find`. POSIX-only stance:

The first-party `todo` companion extension separately registers `todo_write`.
It lets the model overwrite a structured session todo list.
It stores the snapshot in the tool-result `details` payload for replay.
It exposes `/todos`, a TUI panel, a status item, and introspection.

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
- **Same-turn edits to the same file must be batched.** The agent loop detects
  multiple `edit` tool calls in one assistant turn that target the same path,
  rejects those calls with matching tool-result errors, and asks the model to
  retry as one batched edit. This preserves the provider-required one
  `tool_result` per `tool_call` shape while avoiding sequential mutation
  against changing file snapshots.

What's deliberately not ported from pi-mono (per the "balanced" port
decision): file-mutation queue, `bash` streaming/onUpdate, full
process-group abort/signal plumbing (narrow bash kill-on-cancel is #9),
syntax-highlight cache, image MIME detection, edit's fuzzy match + diff
library, fd/rg backends.


