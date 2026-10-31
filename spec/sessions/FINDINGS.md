# Session persistence and replay

Model: [`model.qnt`](model.qnt).
Scope: one JSONL session file and the processes that write it.
The interactive process keeps `agent.messages`, and its flush closure appends new messages on every `:message-appended`, but only after the first assistant message exists.
The model covers turns with one tool call each, cancel (synthetic results plus an `:aborted` marker), `/compact` and auto or tool-driven compaction (also mid-turn, before the compact tool's own result), and the process being killed at any point, including partway through writing a line.
It also covers `--continue` replay, a second process running `fen session send` on the same file, append failures, and `session doctor` and its `--repair`.
A separate `lock` module covers the JSONL backend's stale-lock reclaim with two `send` processes.
`currentSolo` is the current code with only one process allowed to touch the session, so each violation can be traced to the bug that causes it.

Code: `packages/fen/src/fen/session_lifecycle.fnl` (`start!`, `make-flush`, `install!`), `extensions/adapters/session-backends/jsonl/session.fnl` (`append-entry`, `open-existing`, `read-entries`, `load`, `latest-valid-compaction`, `acquire-lock`, `doctor`), `extensions/behaviors/companions/compact/init.fnl` (`find-cut-point`, `finish-compact!`), `packages/fen/src/fen/session_control.fnl` (`run-turn!`), `packages/core/src/fen/core/agent.fnl` (`append-message!`, `build-context`, cancel pairing), `extensions/adapters/providers/anthropic/anthropic_messages.fnl` (`convert-messages`).

The probes were run once as `extensions/adapters/session-backends/jsonl/tests/zz_probe_sessions_jsonl_test.fnl` through `make test TESTS=…` and then deleted.
Output: `6 successes / 0 failures`, with the lines quoted below.

## Bugs

### S1. A crash while a tool runs leaves a tool call with no result, and nothing repairs it on replay for Anthropic

Counterexample (`currentSolo.providerContextValid`): `userPrompt → assistantCall → crash → resume → userPrompt`.
The assistant's tool call is flushed the moment it is appended, before the tool runs, so a process killed during a long `bash` call leaves the log ending at that call.
`load` replays the call unchanged, and the next prompt sends `assistant(tool_use)` followed by a user message.
The agent's cancel path pairs calls in memory, and the OpenAI converters (`openai_completions`, `openai_responses_shared`) add a placeholder for orphaned calls on their own, but the Anthropic converter does not.
A `fen session send` after the crash hits the same problem (`current.providerContextValid` through `otherSend`).

Confirmed: append `user`, `assistant{tool-call call-1}`, close, then `S.load` plus a new user message, then `am.convert-messages`:
`S1 wire: user:text assistant:tool_use user:text`, so no `tool_result` follows the `tool_use`, which the Anthropic Messages API rejects.
`session doctor` does detect this case (`missing_tool_result`), but only when run by hand.

### S2. A torn last line swallows the next appended entry

Counterexample (`currentSolo.compactionResolves`): `userPrompt → assistantCall → crashTorn → resume → userPrompt → cancel → compact`.
`append-entry` writes `json .. "\n"` to a file opened in append mode and never checks that the file ends in a newline.
After a kill partway through a write (stdio breaks long tool-result lines into several `write(2)` calls), the first entry the next writer appends lands on the end of the partial line.
That line is malformed, so `load` skips it, yet `append-entry` returned success: the message gets a `__session-entry-id` and the flush cursor moves past it.
After `--continue`, the first prompt is the entry that disappears.
If that prompt is later chosen as a compaction's first kept message, the compaction points at an entry that cannot be read, so it is silently ignored and the full uncompacted history comes back.
The same torn line also makes `fen session send` fail permanently with `malformed_session`, because `load-strict` rejects any bad line.

Confirmed: header, `user`, `assistant`, then the partial line `{"type":"message","id":"x","mess` with no newline. Then `open-existing`, `append user "three"`, `append assistant "four"`:
`S2 before=2 append-returned-entry=true after=3 roles=user,assistant,assistant strict-ok=false`, so `"three"` is lost even though the append reported success, and the replay now has two assistant turns in a row.

### S3. The flush cursor moves past a failed append, so the message is lost for good

Counterexample (`currentSolo.ackedPersisted`, `currentSolo.replayMatchesMemory`): `failAppend → userPrompt → cancel`.
`make-flush` increments `last-saved` before calling `backend.append` and ignores the return value.
`append-entry` turns any write or open failure (ENOSPC, EIO, a directory that cannot be created) into `log.warn` and returns `nil`.
The message is never retried, and resuming yields a history that no longer matches what the user saw.
If the lost message is a tool call, its result is persisted without it, which is an orphan on replay.

Confirmed with the real `make-flush` and a backend whose first `append` returns `nil` (the same value `S.append` returns when its directory cannot be created: `S3b append-returned=nil`):
after `u1, a1`, then a flush, then `u2`, then another flush, the output is `S3 mem=3 disk=2`, so `u1` is gone and the persisted transcript starts with an assistant message.

### S4. Interactive writers ignore the session lock

Counterexample (`current.providerContextValid`, `current.replayMatchesMemory`): `userPrompt → assistantCall → otherSend`.
Only `session_control.run-turn!` calls `acquire-lock`.
`session_lifecycle.start!` (`fen --continue`) and `/resume` open the same file for append without taking it, so an interactive session and a `fen session send` on the same id, or two `fen --continue` processes in one cwd, write to the file at the same time.
The sender loads a transcript that ends in the interactive process's tool call that has no result yet, so its own provider request is invalid (S1 from the other side).
The interactive process's next result lands after the sender's turn, which splits a call from its result in the log.
Two other checks fail only because of S4: `current.compactionCutKeepsPairs` (`… otherSend → cancel → crash → resume → compact`), since cutting at a user boundary assumes the replayed history is already well paired, and both doctor checks (S5).

Confirmed: `release = S.acquire-lock info` (the sender holds the lock), then two `open-existing` handles A and B on the same path, all succeeding.
Then A appends `A2, call-A`, B appends `B prompt, B reply`, and A appends `result(call-A)`:
`S4 wire: user:text assistant:text user:text assistant:tool_use user:text assistant:text user:tool_result`.
Line-by-line trace: `start!` calls only `backend.latest`, `load`, and `open-existing`, and grepping for `acquire-lock` finds callers only in `session_control.fnl`.

### S5. The doctor checks tool pairing by id, not by order, so it reports clean on unusable transcripts

Counterexample (`current.doctorCleanMeansReplayable`, `current.doctorRepairReplayable`): `userPrompt → assistantCall → otherSend → cancel`.
`doctor` tracks a set of pending call ids, so a result anywhere after its call clears the call.
Messages that come between the call and its result are not reported, and `--repair` copies them unchanged.

Confirmed on the S4 transcript: `S5 doctor issue-count=0` and `S5 repaired wire: … assistant:tool_use user:text assistant:text user:tool_result`.
With one process per session the doctor is sound for every transcript the model reaches (`currentSolo` rows hold).

### S6. Two processes can reclaim the same stale lock

Counterexample (`lockCurrent.lockMutex`, 12 steps): P1 and P2 both read the dead owner, both pass the liveness probe and the re-read, then P1 removes the owner file, rmdirs, mkdirs, and holds the lock.
P2 then runs `os.remove owner`, which deletes P1's owner file or finds none yet, and its `rmdir` succeeds because the directory is empty, so P2's `mkdir` wins too.
The re-read guards against a winner that has already *written* its owner before the other process's check (the existing test covers that ordering), but not against two processes that both pass the check before either removes anything.

Confirmed: lock dir with owner `99999999` (dead). `os.remove` is wrapped so that, just as process Q removes the owner file, process P runs a complete `acquire-lock`:
`S6 P-holds=true Q-holds=true`.

## Candidate fix (modelled as `fixed`)

- Replay repair (S1): `load` (or `build-context`, ahead of every provider) adds a synthetic "interrupted" result right after any tool call whose result is not next, the same rule the OpenAI converters already apply privately.
  This makes the provider adapters simpler, since none of them needs its own repair.
- Torn tail (S2): `open-existing` and `ensure-open!` check the last byte and write `"\n"` first if it is missing (or truncate the partial line), so a torn write costs at most the entry that was being written when the process died.
- Flush cursor (S3): advance `last-saved` only when `append` returns an entry, and stop at the first failure so the next flush retries.
  `finish-compact!` must then refuse when any kept message, not just the first, lacks an entry id.
- One writer (S4, S6): every writer (interactive `start!` and `/resume`, `send`) holds the session lock for as long as it owns the file.
  The lock should be one the kernel drops when the process dies (`lfs.lock` or `flock` on the transcript), not a mkdir directory plus a pid file.
  That removes stale-lock reclaim, and with it S6.
- Doctor (S5): check that results come right after their calls, as the provider does: a call whose result is not next is missing, and a result not right after its call is an orphan.

`fixed.allInvariants` and `lockFixed.lockMutex` hold, including with a second process present.

## What holds today

- `noDuplicateEntries`: the flush cursor never writes a message twice, even across compaction (new cursor = `#messages`), `--continue` (cursor = `#replayed`), handoff (cursor = 1 after the seed append), and cancel.
- With one process per session, compaction keeps tool calls with their results and starts the kept part at a user turn (`currentSolo.compactionCutKeepsPairs`).
  Cutting only at user messages works because the agent loop only adds user messages before the first provider call or once every tool result is in.
  The compact tool runs mid-turn, and its own pending call is always after the last user message, so it is always kept.
- Cancelling a compaction cannot leave a partial result: the only yields are inside the summary model call, and nothing yields between `append-entry` and `replace-agent-messages!`.
- With one process per session, the doctor's repair always replays validly, and a clean report means the transcript replays validly.

## Open questions

- `docs/sessions.md` says the lifecycle "keeps a final turn-completion flush as a safety net", but the interactive path has no such flush; only `session_control.run-turn!` flushes after the turn.
  The per-message `:message-appended` flush makes this harmless, so it looks like doc drift.
- `load-strict` makes durable sessions fail permanently after any torn line (S2), and doctor `--repair` writes a sibling that discovery ignores, so recovery requires a manual `mv`.
  Is that intended for the machine interface?
- After S2, the replay can contain two assistant messages in a row.
  Whether each provider accepts that was not checked.

## Core

The essential contract is small: *the log is a sequence of whole entries written by one owner; a message counts as saved only once its entry is readable; replay of the log is the context, with interrupted tool calls closed off*.
Today that contract is split across pieces: the flush cursor (which trusts appends that may fail), `append-entry` (which trusts the previous writer's last byte), the lock (taken only by `send`), each provider converter (which may or may not repair orphaned calls), and the doctor (which checks pairing differently from the providers).
A minimal core is one `SessionWriter` that owns the lock and the file, terminates any torn tail, and returns the entry id only once the write succeeded.
On top of it sits one pure `replay(entries) -> provider-valid messages` used by `--continue`, `/resume`, `send`, `show`, and the doctor (the doctor would then just report where its input differs from `replay`'s output).
Under that core, compaction is simply another entry type, and its "first kept entry" rule is safe by construction.
