# Sessions

Session persistence format and CLI behavior.

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


