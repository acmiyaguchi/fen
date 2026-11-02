# Session persistence and replay

Model: [`model.qnt`](model.qnt).
Scope: one JSONL session file and the processes that write it.
The interactive process keeps `agent.messages`, and its flush closure appends new messages on every `:message-appended`, but only after the first assistant message exists.
The model covers turns with one tool call each, cancel (synthetic results plus an `:aborted` marker), `/compact` and auto or tool-driven compaction (also mid-turn, before the compact tool's own result), and the process being killed at any point, including partway through writing a line.
It also covers `--continue` replay, a second process running `fen session send` on the same file, append failures, and `session doctor` and its `--repair`.
The JSONL backend's stale-lock reclaim with two `send` processes is the [`lock` proof model](proofs/lock/model.qnt); the `lockCurrent`/`lockFixed` rows here run its instances.
`currentSolo` is the current code with only one process allowed to touch the session, so each violation can be traced to the bug that causes it.

Code: `packages/fen/src/fen/session_lifecycle.fnl` (`start!`, `make-flush`, `install!`), `extensions/adapters/session-backends/jsonl/session.fnl` (`append-entry`, `open-existing`, `read-entries`, `load`, `latest-valid-compaction`, `acquire-lock`, `doctor`), `extensions/behaviors/companions/compact/init.fnl` (`find-cut-point`, `finish-compact!`; `/compact` and auto run as exclusive jobs via `start-compact!` -> `tasks.run-exclusive!`, the `compact` tool inline via `execute-tool`), `extensions/behaviors/companions/handoff/init.fnl` (`start-handoff!` -> `tasks.run-exclusive!`, `finish-handoff!`), `packages/core/src/fen/core/tasks.fnl` (`request-job!`, `schedule!`, `cancel-requested?`), `packages/fen/src/fen/session_control.fnl` (`run-turn!`), `packages/core/src/fen/core/agent.fnl` (`append-message!`, `build-context`, cancel pairing), `extensions/adapters/providers/anthropic/anthropic_messages.fnl` (`convert-messages`).

The bugs were first confirmed by a throwaway probe (`zz_probe_sessions_jsonl_test.fnl`, `6 successes / 0 failures`, lines quoted below).
Each had a `known-bug` probe against the real code; the probes are now regression tests (see "Evidence per bug").

## Audit after #686 (session holder)

The model still matches, now as an over-approximation for the idle paths:

- `/compact` and auto-compaction are exclusive jobs (`start-compact!`, `extensions/behaviors/companions/compact/init.fnl:287`). They start only when no holder exists, i.e. after the turn's `close-turn!` has paired every call, so in code they never run mid-tool; `compact(cut)` still allows that and the invariants hold anyway.
- The only mid-turn compaction is the `compact` tool (`execute-tool`, `compact/init.fnl:391`), which calls `finish-compact!` inline in the turn coroutine, unchanged by #686: the cut is at a user message, so the open assistant call stays in `kept` and its result is appended afterwards. A cancel unwinds through the turn's yield to the agent's cancelled result.
- A cancelled `/compact` or `/handoff` job raises CANCEL-MARKER from `make-yield` (fenced on the job's hid, `compact/init.fnl:197`, `handoff/init.fnl:92`) during the summary call, before `append-entry` or `reset-agent-session!`, so no compaction entry is written and the messages stay as they were: a no-op, as modelled (`compact` is atomic).
- `/handoff` replaces the session with one summary message, so it has no tool pairs; it runs from a paired idle history.
- Quitting with a suspended turn (`turn-submit.drop!` at presenter exit) is the `crash` action (#639).

## Input assumptions

What the environment actions of [`model.qnt`](model.qnt) can and cannot produce:

- Turns have at most one tool call each, and message ids are never reused (`nextMid` only grows, bounded by `MAX_MID = 12`).
- `crash(true)` (a torn write) happens only during a turn (`phase != idle`), on a non-empty log whose last line is whole; at most one partial line is ever open.
- `failAppend` arms one failure for the next write; failures are transient (the write after it succeeds). Persistent failures are not modelled.
- `otherSend` is one complete `fen session send` turn (user plus text reply, no tools) done atomically between two interactive steps; it never runs on a log with a malformed line (`load-strict` refuses), and only when `OTHER_WRITER`. Sends with tool calls, and two senders, are not generated.
- `compact(cut)` cuts at any user message after index 0 (an over-approximation of `find-cut-point`'s token budget), idle or mid-tool.
- The second process, the lock, and replay laws for arbitrary logs are each covered elsewhere: the lock in [`proofs/lock`](proofs/lock/model.qnt) (two senders and one dead owner; the owner pid is never reused), replay laws in the coordinator's replay obligation.

[`proofs/persistence`](proofs/persistence/model.qnt) generates only: in-order messages (ids 1..5), one-message appends from the cursor, a one-shot write failure, crashes (torn only while an append is pending), and `--continue`. No compaction, roles, or second writer.


## Bugs

### #639: A crash while a tool runs leaves a tool call with no result, and nothing repairs it on replay for Anthropic

Counterexample (`currentSolo.providerContextValid`): `userPrompt → assistantCall → crash → resume → userPrompt`.
The assistant's tool call is flushed the moment it is appended, before the tool runs, so a process killed during a long `bash` call leaves the log ending at that call.
`load` replays the call unchanged, and the next prompt sends `assistant(tool_use)` followed by a user message.
The agent's cancel path pairs calls in memory, and the OpenAI converters (`openai_completions`, `openai_responses_shared`) add a placeholder for orphaned calls on their own, but the Anthropic converter does not.
A `fen session send` after the crash hits the same problem (`current.providerContextValid` through `otherSend`).

Confirmed: append `user`, `assistant{tool-call call-1}`, close, then `S.load` plus a new user message, then `am.convert-messages`:
`S1 wire: user:text assistant:tool_use user:text`, so no `tool_result` follows the `tool_use`, which the Anthropic Messages API rejects.
`session doctor` does detect this case (`missing_tool_result`), but only when run by hand.

### #640: A torn last line swallows the next appended entry

Counterexample (`currentSolo.compactionResolves`): `userPrompt → assistantCall → crashTorn → resume → userPrompt → cancel → compact`.
`append-entry` writes `json .. "\n"` to a file opened in append mode and never checks that the file ends in a newline.
After a kill partway through a write (stdio breaks long tool-result lines into several `write(2)` calls), the first entry the next writer appends lands on the end of the partial line.
That line is malformed, so `load` skips it, yet `append-entry` returned success: the message gets a `__session-entry-id` and the flush cursor moves past it.
After `--continue`, the first prompt is the entry that disappears.
If that prompt is later chosen as a compaction's first kept message, the compaction points at an entry that cannot be read, so it is silently ignored and the full uncompacted history comes back.
The same torn line also makes `fen session send` fail permanently with `malformed_session`, because `load-strict` rejects any bad line.

Confirmed: header, `user`, `assistant`, then the partial line `{"type":"message","id":"x","mess` with no newline. Then `open-existing`, `append user "three"`, `append assistant "four"`:
`S2 before=2 append-returned-entry=true after=3 roles=user,assistant,assistant strict-ok=false`, so `"three"` is lost even though the append reported success, and the replay now has two assistant turns in a row.

### #641: The flush cursor moves past a failed append, so the message is lost for good

Counterexample (`currentSolo.ackedPersisted`, `currentSolo.replayMatchesMemory`): `failAppend → userPrompt → cancel`.
`make-flush` increments `last-saved` before calling `backend.append` and ignores the return value.
`append-entry` turns any write or open failure (ENOSPC, EIO, a directory that cannot be created) into `log.warn` and returns `nil`.
The message is never retried, and resuming yields a history that no longer matches what the user saw.
If the lost message is a tool call, its result is persisted without it, which is an orphan on replay.

Confirmed with the real `make-flush` and a backend whose first `append` returns `nil` (the same value `S.append` returns when its directory cannot be created: `S3b append-returned=nil`):
after `u1, a1`, then a flush, then `u2`, then another flush, the output is `S3 mem=3 disk=2`, so `u1` is gone and the persisted transcript starts with an assistant message.

### #642: Interactive writers ignore the session lock

Counterexample (`current.providerContextValid`, `current.replayMatchesMemory`): `userPrompt → assistantCall → otherSend`.
Only `session_control.run-turn!` calls `acquire-lock`.
`session_lifecycle.start!` (`fen --continue`) and `/resume` open the same file for append without taking it, so an interactive session and a `fen session send` on the same id, or two `fen --continue` processes in one cwd, write to the file at the same time.
The sender loads a transcript that ends in the interactive process's tool call that has no result yet, so its own provider request is invalid (#639 from the other side).
The interactive process's next result lands after the sender's turn, which splits a call from its result in the log.
Two other checks fail only because of #642: `current.compactionCutKeepsPairs` (`… otherSend → cancel → crash → resume → compact`), since cutting at a user boundary assumes the replayed history is already well paired, and both doctor checks (#643).

Confirmed: `release = S.acquire-lock info` (the sender holds the lock), then two `open-existing` handles A and B on the same path, all succeeding.
Then A appends `A2, call-A`, B appends `B prompt, B reply`, and A appends `result(call-A)`:
`S4 wire: user:text assistant:text user:text assistant:tool_use user:text assistant:text user:tool_result`.
Line-by-line trace: `start!` calls only `backend.latest`, `load`, and `open-existing`, and grepping for `acquire-lock` finds callers only in `session_control.fnl`.

### #643: The doctor checks tool pairing by id, not by order, so it reports clean on unusable transcripts

Counterexample (`current.doctorCleanMeansReplayable`, `current.doctorRepairReplayable`): `userPrompt → assistantCall → otherSend → cancel`.
`doctor` tracks a set of pending call ids, so a result anywhere after its call clears the call.
Messages that come between the call and its result are not reported, and `--repair` copies them unchanged.

Confirmed on the #642 transcript: `S5 doctor issue-count=0` and `S5 repaired wire: … assistant:tool_use user:text assistant:text user:tool_result`.
With one process per session the doctor is sound for every transcript the model reaches (`currentSolo` rows hold).

### #644: Two processes can reclaim the same stale lock

Counterexample (`lockCurrent.lockMutex`, 12 steps): #631 and #632 both read the dead owner, both pass the liveness probe and the re-read, then #631 removes the owner file, rmdirs, mkdirs, and holds the lock.
#632 then runs `os.remove owner`, which deletes #631's owner file or finds none yet, and its `rmdir` succeeds because the directory is empty, so #632's `mkdir` wins too.
The re-read guards against a winner that has already *written* its owner before the other process's check (the existing test covers that ordering), but not against two processes that both pass the check before either removes anything.

Confirmed: lock dir with owner `99999999` (dead). `os.remove` is wrapped so that, just as process Q removes the owner file, process P runs a complete `acquire-lock`:
`S6 P-holds=true Q-holds=true`.

## Fixed in #605

All of #639-#644 are fixed in the code, and `current`, `currentSolo` and `lockCurrent` (and the persistence proof's `current`) now enable the fixes, so their former `violated` rows are `holds`.
The `fix<issue>` and `fix640641` rows are unchanged, and the single-fix survival witnesses (`w640SurvivesFix641Test`, `w641SurvivesFix640Test`) stay.
The counterexample witnesses became `reach...Test` traces on the fixed design.

- Replay repair (#639, #643): `replay-plan` / `replay-messages` in `extensions/adapters/session-backends/jsonl/session.fnl` is the one pairing rule: a call whose result does not follow it gets a synthetic interrupted result (in memory only), and a result that answers no open call is dropped. `load`, `transcript` (so `--continue`, `/resume`, `send` and `show`) and `doctor` all use it, so the doctor reports and repairs exactly what replay changes (`missing_tool_result`, `orphan_tool_result`).
- Torn tail (#640): `open-existing` and the first append terminate a last line that lacks a newline (`terminate-torn-tail!`), under the writer lock.
- Flush cursor (#641): `session_lifecycle.make-flush` advances `last-saved` only when `backend.append` returns an entry, stops at the first failure and returns whether everything is saved; the JSONL `append` drops its handle after a failed write so the next one re-terminates the line.
- One writer (#642, #644): every writable handle (`open-existing`, a new session on its first write) holds a kernel record lock (`lfs.lock`) on `<transcript>.writer.lock` until `close`, released by the kernel when the process dies, so there is no stale lock to reclaim. `start!` and `/resume` open (and lock) before they read; `session_control.run-turn!` uses the same handle lock. A second interactive `--continue` exits 2 with a message, `/resume` reports an error. Without `lfs.lock` only writers in one process are excluded (logged).

## Candidate fix (modelled as `fixed`)

- Replay repair (#639): `load` (or `build-context`, ahead of every provider) adds a synthetic "interrupted" result right after any tool call whose result is not next, the same rule the OpenAI converters already apply privately.
  This makes the provider adapters simpler, since none of them needs its own repair.
  `fixed` uses the close-turn core's `replayPlan` (`spec/core/turn`), the same rule the agent loop's `fixed` applies when a step unwinds; it also drops results that answer no pending call.
- Torn tail (#640): `open-existing` and `ensure-open!` check the last byte and write `"\n"` first if it is missing (or truncate the partial line), so a torn write costs at most the entry that was being written when the process died.
- Flush cursor (#641): advance `last-saved` only when `append` returns an entry, and stop at the first failure so the next flush retries.
  `finish-compact!` must then refuse when any kept message, not just the first, lacks an entry id.
- One writer (#642, #644): every writer (interactive `start!` and `/resume`, `send`) holds the session lock for as long as it owns the file.
  The lock should be one the kernel drops when the process dies (`lfs.lock` or `flock` on the transcript), not a mkdir directory plus a pid file.
  That removes stale-lock reclaim, and with it #644.
- Doctor (#643): report and repair exactly what replay would change (core `replayRepairs` / `replayPlan`), so the doctor and the providers cannot disagree: a call whose result is not next is missing, and a result not right after its call is an orphan.

Each fix is named (`FIXES` holds issue numbers): `fixed` enables all of #639–#643, and `lockFixed` (in the lock proof model) #644.
`fixed.allInvariants` and `lockFixed.lockMutex` hold, including with a second process present (sampled).
One fix at a time (sampled, `fix<issue>` instances, one process per session unless the fix needs the second one):

| Instance | Holds | Still violated |
| --- | --- | --- |
| `fix639` | `providerContextValid` | |
| `fix640` | `compactionResolves` | `ackedPersisted` (#641) |
| `fix641` | | `ackedPersisted` (#640) |
| `fix640641` | `ackedPersisted`, `replayMatchesMemory`, `compactionResolves` | |
| `fix642` (second process) | `compactionCutKeepsPairs`, both doctor checks | |
| `fix643` (second process) | both doctor checks | |

So #640 and #641 are both needed for an acknowledged message to be readable, and #642 alone already makes the doctor sound, because the interleaving #643 misreads cannot arise; #643 still matters for logs written before the fix or by other tools.

## Proof models

Measured with `SPEC_VERIFY_JOBS=1 JVM_ARGS=-Xmx3g` (Apalache 0.56.1).

| Model | Obligation | Kind | Result |
| --- | --- | --- | --- |
| [`proofs/persistence`](proofs/persistence/model.qnt) | `fixed.persistInductive` (implies `ackedReadable`, `replayMatchesMemory`) | inductive | holds, 1–8 s |
| | `fixed.allInvariants`, 8 steps | bounded-safe | holds, 2–3 s |
| [`proofs/lock`](proofs/lock/model.qnt) | `lockFixed.lockInductive` (implies `lockMutex`) | inductive | holds, 3–5 s |

`persistInductive` says: every readable id was allocated, every acknowledged entry is readable, and under a live writer there is no partial line, the writer holds every readable entry, every message up to the cursor is readable, and every message past it is still in memory.
`lockInductive` says: with the kernel lock no process enters the reclaim states; a holder implies the lock is held by a live owner; the owner file names the holder.
Both inductions fail (Apalache counterexample) when a conjunct is dropped or for the instances missing a fix (checked once by hand: `fix640`/`fix641` for persistence, `lockCurrent` for the lock), so they are not vacuous.
The #644 race needs 12 steps; the inductive invariant covers any depth, so no 12-step bound is needed.
`current` instances of both proof models reproduce their bugs as counterexamples (`violated` rows with witnesses).

## Evidence per bug

| Bug | Counterexample (row) | Witness (`witnesses.qnt`) | Proof model | Probe (confirmed) |
| --- | --- | --- | --- | --- |
| #639 | `currentSolo.providerContextValid`, `current.providerContextValid` | `w639CrashLeavesUnpairedCallTest` | (replay obligation) | `extensions/adapters/session-backends/jsonl/tests/replay_closes_interrupted_tool_call_test.fnl` |
| #640 | `currentSolo.compactionResolves`, `fix641.ackedPersisted`; `proofs/persistence` `current.ackedReadable` | `w640TornTailSwallowsAppendTest`, `w640SurvivesFix641Test` | persistence (inductive for the fix) | `extensions/adapters/session-backends/jsonl/tests/torn_tail_terminated_before_append_test.fnl` |
| #641 | `currentSolo.ackedPersisted`, `currentSolo.replayMatchesMemory`, `fix640.ackedPersisted`; `proofs/persistence` `current.ackedReadable` | `w641CursorPassesFailedAppendTest`, `w641SurvivesFix640Test` | persistence (inductive for the fix) | `packages/fen/tests/flush_cursor_retries_failed_append_test.fnl` |
| #642 | `current.providerContextValid`, `current.replayMatchesMemory`, `current.compactionCutKeepsPairs` | `w642SendDuringInteractiveTurnTest` | — | `extensions/adapters/session-backends/jsonl/tests/continue_refuses_locked_session_test.fnl` |
| #643 | `current.doctorCleanMeansReplayable`, `current.doctorRepairReplayable` | `w643DoctorCleanOnInterleavedTest` | — | `extensions/adapters/session-backends/jsonl/tests/doctor_pairs_by_order_test.fnl` |
| #644 | `lockCurrent.lockMutex` | `w644DoubleReclaimTest` (here and in `proofs/lock`) | lock (inductive for the fix) | `extensions/adapters/session-backends/jsonl/tests/writer_lock_single_holder_test.fnl` |

The probes below reproduced the bugs before #605; they are now ordinary tests asserting the fixed behaviour (the `w<issue>` witnesses named in the table were converted to `reach...Test` traces except the survival ones):

- #639: a log ending at a tool call goes through `load`, then a new user message, then the Anthropic `convert-messages`; the wire shape is `user:text assistant:tool_use user:text`.
- #640: after a torn last line, `open-existing` plus `append "three"` returns an entry id, yet replay has 3 messages (`user,assistant,assistant`) and `load-strict` fails.
- #641: `S.append` returns nil when its directory cannot be created, and the real `make-flush` with a backend whose first append fails gives `mem=3 disk=2`.
- #642: while a sender holds `acquire-lock`, the real `session_lifecycle.start! {:continue? true}` opens a writable handle without calling `acquire-lock` (0 calls), and the two writers' appends interleave. The sender side is an `open-existing` in the same process, not a second OS process.
- #643: on that interleaved transcript `doctor` reports 0 issues, and `--repair` keeps the split pair.
- #644: lock dir with a dead owner; `os.remove` is wrapped so a second `acquire-lock` runs at the moment the first removes the owner file, and both get a release function. The two "processes" share one OS process (a real race cannot be run deterministically).

Mutants (`mutants.tsv`, run by `check-spec`): removing each candidate fix from the integration model (#639 replay repair, #640 torn-tail termination, #641 cursor stop and the all-kept compaction check, #642 lock, #643 doctor) is caught by the named invariant; the #643 mutant runs on `fix643`, because in `fixed` the #642 lock already rules out the interleaving. Each proof model has its own mutants.

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
- `load-strict` makes durable sessions fail permanently after any torn line (#640), and doctor `--repair` writes a sibling that discovery ignores, so recovery requires a manual `mv`.
  Is that intended for the machine interface?
- After #640, the replay can contain two assistant messages in a row.
  Whether each provider accepts that was not checked.

## Core

The essential contract is small: *the log is a sequence of whole entries written by one owner; a message counts as saved only once its entry is readable; replay of the log is the context, with interrupted tool calls closed off*.
Today that contract is split across pieces: the flush cursor (which trusts appends that may fail), `append-entry` (which trusts the previous writer's last byte), the lock (taken only by `send`), each provider converter (which may or may not repair orphaned calls), and the doctor (which checks pairing differently from the providers).
A minimal core is one `SessionWriter` that owns the lock and the file, terminates any torn tail, and returns the entry id only once the write succeeded.
On top of it sits one pure `replay(entries) -> provider-valid messages` used by `--continue`, `/resume`, `send`, `show`, and the doctor (the doctor would then just report where its input differs from `replay`'s output).
Under that core, compaction is simply another entry type, and its "first kept entry" rule is safe by construction.
