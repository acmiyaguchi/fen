# Wire protocol (live subagent)

Model: [`model.qnt`](model.qnt).
Scope: one parent and one live child connected by two append-only JSONL files.
The child is `fen --presenter rpc`: it reads every unread control line at the top of its loop, sends one `control-ack`, and acts through the `wire_session` table.
It runs turns cooperatively, with a steering queue, a ref FIFO, a deadline, crashes, the oversized-answer spill, and `result`/`exit`.
The parent is the `subagent` extension.
It sends the task `prompt` before spawning the child and reads 1..n event lines per poll.
It mirrors the state with `decide` on each non-rejected ack, `advance` on `turn-complete`, and `exit`.
`drive!` sends user steers, a budget `finalize` (mirror `running` only), `close` when `idle?`, and `cancel` with kill-after-grace.
At settle it reads `final-text-path` back and removes the file.
An `external` scenario lets a third-party parent send `close`/`finalize` in any state (close mid-turn, finalize while closing, close while finalizing).

Code: `packages/util/src/fen/util/wire.fnl` (`receive!`, `rejection-ack`, `read-lines!`), `packages/util/src/fen/util/wire_session.fnl` (`decide`, `advance`), `extensions/adapters/presenters/rpc/init.fnl` (`apply-control!`, `poll-controls!`, `perform!`, `turn-ended!`, `finish!`, `drop-queued!`, `take-ref!`, `result-line`, `spill-final-text`), `extensions/behaviors/companions/subagent/channel.fnl` (`send!`, `mirror!`, `idle?`), `extensions/behaviors/companions/subagent/init.fnl` (`drive!`, `maybe-finalize!`, `finish!`, `result-final-text`), `extensions/behaviors/kernel/steering/service.fnl`, `packages/core/src/fen/core/agent.fnl` (`inject-user-lines!`, `inject-after-natural-stop!`).

Simplifications: `follow-up` is not modelled, because the in-tree parent never sends it.
It would use a second FIFO with the same text-matching rule as `steer`.
Each child action is atomic, either a whole poll batch or a whole turn end; the parent may still read part of the event file.
Random simulation picks one disruption kind per trace (`scenario`), so its steps go to interleavings.
The child's internal `fatal` event (a control line of another wire version, a control file truncated below the read offset, a turn that throws) is modelled as `childFatal` and `childTurnThrow` (`scenario = fatal`), and `advance` has the code's `fatal` rows.

## Input assumptions

What the environment actions can produce:

- The parent appends controls in seq order (`send`), one at a time; an `external` parent may append `close` or `finalize` in any state.
- The child reads every unread control line in one batch (`childPoll`) and handles the batch before anything else it does.
- A turn calls at most `MAX_TOOLCALLS` tools; at most `MAX_STEERS` user steers are requested; steer text is empty only in `scenario = empty`.
- Exactly one disruption kind per trace: a crash (`childCrash`, or the parent's kill after `cancel`), the deadline (once), a fatal error (once, outside or inside a turn), a user cancel, a provider error ending the turn, an empty steer, a long answer, a long answer plus death between the spill and the result line, or an external parent.
- The parent reads 1..n new event lines per poll and stops at `exit`; it settles once the child is gone.

What they cannot produce: torn or malformed control lines other than the version-mismatch `fatal`, out-of-order seqs, `follow-up` controls, a child that exits without its event file (the parent's crash handling is the subagents domain's), and a parent that dies (no orphan child is modelled here).

## Bugs

### #664: A steer sent once the child is committed to exit is never answered nor reported (`everyReadControlAcked`, `userSteersAccounted`, `noDoomedSteer`)

Counterexample (in-tree parent, no disruption): `childStart → childPoll(prompt) → childAnswer → parentPoll → parentDrive(close) → userSteer → parentDrive(steer) → childPoll`.
The parent's mirror is `ready` with nothing unacked, so it sends `close`.
The user's next `/subagents steer` (answered "Queued steering for …") is sent after it.
`drive!` never looks at the mirror or `close-sent?` before sending steers, even once the close ack has moved the mirror to `done`.
The child reads `[close, steer]` as one batch.
`close` in `ready` runs `finish!` → `result` → `exit done`, and `poll-controls!` skips the rest of the batch (`(when (and (not ch.exited?) …))`).
The steer gets no ack, no rejection, and no drop notice.
The same steer is lost when it lands after `exit`, and also when the user's request arrives after the parent has read `exit` (`drive!` stops sending, and nothing reports `pending-steering`).
The parent's `unacked` map is consulted only by `idle?`, so the run settles `completed` and the steer silently vanishes.
docs/wire.md promises "Every control line gets exactly one `control-ack`".
The in-tree test "records a steer the child rejects and keeps running" uses a fake child that answers such a steer with `rejected "run is closing"`, which the real child never does (`close` in `ready` goes straight to `done`).

Witnesses: `w664BatchSkipsSteerTest` (`everyReadControlAcked`), `w664DoomedSteerSentTest` (`noDoomedSteer`), `w664SteerUnreportedTest` (`userSteersAccounted`); in the acks proof model, `w664BatchSkipsSteerTest`.

Confirmed against the real child (probe `extensions/adapters/presenters/rpc/tests/issue_664_steer_after_close_unacked_test.fnl`): prompt → wait `turn-complete` → append `close` and `steer` back to back.

```
W1 types:  ready control-ack turn-started … turn-complete control-ack result exit
W1 acks for close(2): 1   steer(3): 0
W1 info events: 0
```

Confirmed against the real parent (probe `extensions/behaviors/companions/subagent/tests/issue_664_steer_after_close_parent_test.fnl`, fake child answering as the real one does, so this half composes two real observations): the fake child acks `close`, then the user requests a steer and the fake child yields, so the parent pumps, reads the close ack, and sends the steer; then `result`/`exit done`.

```
W1p controls: prompt close steer
W1p run status: completed  is-error? false
W1p events: subagent-start agent-started assistant-text llm-end steering subagent-done
```

The run has no `steering-rejected` event.
A second case, where the steer is requested after `exit` was emitted, gives `W1b controls: prompt close`: the steer is never sent and has no event either.

### #665: A budget `finalize` sent on a stale mirror replaces a finished answer (`naturalAnswerKept`)

Counterexample: `childStart → childPoll(prompt) → childToolCall → parentPoll → parentPoll → childAnswer → parentDrive(finalize) → childPoll`.
`maybe-finalize!` fires when the parent has read the tool call that hit `max-tool-calls` (or the artifact checkpoint timer fires) but not yet the final answer.
Its only guard against "the task turn is done" is the mirror being `running`, which lags the child.
If the child finishes its turn before it reads the control, `finalize` arrives in `ready`.
The table maps it to `start-finalize-turn`, so the child runs an extra tool-free LLM turn ("Investigation budget reached…") and `result` carries the forced answer instead of the one already produced.
The run is also flagged `budget-limited?`.
The comment in `maybe-finalize!` ("In `ready` the task turn is done and `close` returns it") states the intended rule, but the protocol cannot express it.

Witness: `w665FinalizeReplacesAnswerTest`.

Confirmed against the real child (probe `extensions/adapters/presenters/rpc/tests/issue_665_finalize_after_answer_test.fnl`): prompt → `turn-complete` → `finalize`.

```
W2 types: … turn-complete control-ack turn-started … turn-complete result exit
W2 turn-started count: 2   result: forced answer
```

Confirmed against the real parent (probe `extensions/behaviors/companions/subagent/tests/issue_665_finalize_stale_mirror_parent_test.fnl`): the fake child emits a tool call (with `max-tool-calls 1`) and yields; the parent sends `finalize`.
The fake child then ends its turn with a final answer before reading the control and answers `finalize` per the real table.

```
W2p controls: prompt finalize
W2p answer: forced answer  budget-limited? true
```

### #666: An empty steer is accepted but never injected, and it blinds ref matching for every later steer (`queuedSteersAccounted`)

Counterexample (`scenario = empty`): two steers, the first with text `""`, both queued in `running`, then the turn ends and the run closes.
The schema allows `text: ""`, and `decide(running, steer)` queues it.
`inject-user-lines!` skips `""` without an event, but `take-ref!` only pops the FIFO head when its text equals the injected text.
The empty entry therefore stays at the head forever, and every later steer is injected with no `ref`.
At exit, `drop-queued!` counts the *service* queue (now empty), so `n = 0` and no `info` is sent, even though `pending` still holds both refs.
Two accepted controls end up neither injected-with-ref nor reported dropped.
`inject-after-natural-stop!` also treats `[""]` as input, so the agent makes one extra provider call with nothing new to say.
Fen's own parent trims and rejects empty notes, so this affects external parents only, but the wire protocol is a documented contract.

Witness: `w666EmptySteerUnaccountedTest`.

Confirmed against the real child (probe `extensions/adapters/presenters/rpc/tests/issue_666_empty_steer_blinds_refs_test.fnl`): steer `""` then steer `"real steer"` during a tool, then close.

```
W3 ack 2: accepted  ack 3: accepted
W3 steering-injected text= real steer  ref= nil  refs= nil
(no info event)
```

### #667: The spilled final-text file leaks when the child dies between spilling and the result line (`finalTextFileRemovedOnce`)

Counterexample (`scenario = longCrash`): `… childAnswer → envCrashAtResult → parentDrive(close) → childPoll(close: spill, then die) → parentSettle`.
`result-line` writes the whole answer to `os.tmpname()` *before* the `result` line is appended.
The path reaches the parent only inside that line.
A child killed in between (the parent's process timeout, OOM, or kill -9), or a failed append (`send!`/`finish!` ignore `write`'s return), leaves a private temp file holding the full answer that nobody knows about.
The parent's `finish!` removes the control, event, and system-prompt files it named, but it cannot name this one.
Every other path removes the file exactly once (`result-final-text` runs once per settle).

Witness: `w667SpillLeaksOnCrashTest`.

Confirmed against the real child (probe `extensions/adapters/presenters/rpc/tests/issue_667_spill_file_leaks_test.fnl`, which removes the leaked file afterwards): `ch.out:write` raises on the result line, standing in for death at that instant.

```
W4 run ok? false  …: killed while writing result
W4 spill file 3 exists? true  bytes 102400
```

Severity is low because the window is narrow, but the ownership rule ("the parent owns that file") is unenforceable as designed.

## Candidate fixes (named: `FIXES`)

Each fix is guarded by its issue number; `fixed` enables all four, and `fix664`, `fix665`, `fix666`, `fix667` enable one each.
Every `fix<n>` instance makes its own issue's rows hold (sampled), so the fixes are independent.

- `664` — Child: defer the exit a control causes to the end of its poll batch, so every line read gets an ack (`decide` in a terminal state rejects the rest), with `result`/`exit` still last (#664, `everyReadControlAcked`).
- Parent: keep a steer ledger, so every steer the user was told about ends `injected`, `rejected`, `dropped`, or unanswered.
  At settle, report every unsent or unresolved steer as dropped, and hold steers once `close` is sent or the mirror leaves `starting`/`ready`/`running` (#664).
- `665` — `decide(ready, finalize)` is `finish`: a finalize that finds the turn already over keeps its answer and emits `result` (#665).
  This changes the documented meaning of finalize from `ready`.
  A narrower alternative is a conditional control, `finalize {turn: N}`, that applies only while turn N is running and otherwise acts as `close`.
- `666` — Reject empty `steer`/`follow-up` text, either in `decide` or with `minLength: 1` in the schema (#666).
  More robustly, carry the control `ref` on the queue item instead of matching by text, and count drops from `pending`, not from the service queue.
- `667` — The parent names the spill file (as it names the control and event files, e.g. `FEN_WIRE_RESULT_PATH`) and always removes it in `finish!` (#667).

Every invariant holds under `fixed` (sampled).
Reachability witnesses (`reach...Test` in `witnesses.qnt`) show the fixed design still completes a run, injects a steer with its ref, holds and reports a steer sent after close, acks a two-control batch that ends the run, keeps the answer on the #665 schedule, runs the tool-free turn on a budget finalize mid-turn, rejects the empty steer, removes the spill file on the #667 schedule, and exits cancelled, timed-out, and failed (fatal idle, fatal mid-turn, a throwing turn).
Mutants (`mutants.tsv`) undo each named fix and two guards (`result` after `exit`; `fatal` no longer failing the run); each is caught.

## Proof model: acks (`proofs/acks/`)

The child's control loop only: three control slots (the prompt and two appended controls of any kind), the read offset, how many read lines have been handled, one ack counter per slot, the run state, the turn, and the last two lifecycle events, all scalars.
A poll takes every unread line; the loop handles them one per step (`childApply`) before it ticks the turn or polls again, which is what `poll-controls!` does inside one loop iteration.
The `decide`/`advance` rows are copied from the integration model (pinned to the code by conformance) for the controls modelled.

| main | obligation | result | time |
| --- | --- | --- | --- |
| `fixed` | `fixedInductive` (acks once, every handled line acked, nothing unread acked, `result` once and right before `exit done`) | inductive | 5–7 s |

`current` fails the same obligation (counterexample, 17 s), and `w664BatchSkipsSteerTest` is its 10-step trace.
The strengthening needed: an exit waits for the end of the batch (`pend != ""` only mid-batch, `exited` only at a batch boundary), a turn runs exactly in `running`/`closing`/`finalizing` (and while a terminal run unwinds), `done` before exit only with `finish` pending, and `result` is never the last event.

## Conformance

`conform.sh` runs two comparisons; `check-spec` runs it and `conform.sh --negative`, which must fail.

- **Table** (`conform.qnt`, `scripts/spec/conform-wire.fnl`): every (state, control) and (state, event) pair of the model's `decide`/`advance`, including `fatal`, equals `fen.util.wire_session`; and every state, control, and event in the code's `STATES`, `CONTROLS`, `TRANSITIONS`, and `EVENTS` is covered by the model's lists, so a code-only row cannot escape (226 checks). Before this change the model had no `fatal` rows and the comparison passed anyway; the completeness check reports 9 mismatches on that model.
- **Lifecycle** (`lifecycle_test.fnl`): 300 traces of `current` (16 steps, seed `0x5eed`) are replayed through the real rpc child (`fen.extensions.rpc`, the real `wire_session` table, the cooperative agent loop, the mock provider) by a scripted parent. Each model poll batch is written to the control file when the model's child polls; the child's turn is resumed only as far as the model's next child action (a gate tool holds each tool call; the mock provider answers what the model's step says). After every step, the child's lifecycle events must equal the model's `c.out` in order: `ready`, `control-ack` with ref and status (so one ack per control), `turn-started`, `turn-complete`, the drop notice and its refs, `result`, and `exit` with its status. A `result` naming `final-text-path` must have spilled the full answer there and the model must agree it spilled; the replay removes the file. Today 93 of 300 traces are replayable (scenarios none, cancel, deadline, fatal, external, empty, long) and none diverges (0.4 s); `--negative` replays `fixed` traces, of which 14 diverge.

Not covered by the lifecycle replay, and why:

- Steering injection: the real agent drains its queue at its own loop points, which the model abstracts to one nondeterministic `childInject`; traces with a steer queued mid-turn are skipped, so drop notices with refs are not exercised (the #666 probe covers them).
- Provider errors, throwing turns, child crash, the parent's kill, and death between the spill and the result line: they need fault injection inside one process (the #667 probe covers the last).
- The parent mirror and settle (`parentPoll`, `parentDrive`, `parentSettle`): the replay's parent is a script, not the subagent extension, so the parent side and spill-file removal by the parent are covered only by the subagent extension's tests and the #664/#665 parent probes.

## What holds

Evidence: sampled (`holds` rows), plus inductive for the child-side ack and result properties under fix 664 (acks proof model), plus confirmed by the lifecycle replay for the traces it covers.

- `atMostOneAck`: no control is answered twice, including out-of-order and rejected lines.
- `ackBeforeEffect`: every `steering-injected` ref and every drop-notice ref comes after that control's ack.
  `apply-control!` acks before `perform!`, and `turn-started` follows the ack.
- `resultOnlyBeforeExitDone`: `result` appears at most once, immediately before `exit done`, and never for cancelled, failed, or timed-out runs.
  `finish!` sends the drop notice first, and the second `drop-queued!` inside `exit!` is a no-op.
- `mirrorAgreesWhenDrained`: with the event file drained, the parent's mirror equals the child's state across idle turns, deadline, fatal, cancel, finalize from `running` or `closing`, and close while finalizing.
  Every non-terminal transition the child makes is announced (`ready`, ack, `turn-started`, `turn-complete`), and the two sides share one table.
  The one exception is excluded on purpose: after a deadline or fatal error with a turn in flight, the child is already terminal but says nothing until the turn unwinds and `exit` lands.
  Meanwhile the mirror says `running`, and controls sent in that window are rejected ("run is timed-out").
  This is visible, not lost.
- `controlSeqIncreasing`: control `seq` values strictly increase.
  `receive!` consumes any readable increasing seq even when the payload is rejected, so a gap never wedges the stream.

## Open questions

- Idle follow-up in a non-`ready` state: `tick!` runs `on-tick` before `turn-ended!`.
  If an extension calls `api.enqueue(:follow-up …, {:start-if-idle? true})`, `start-idle-follow-up!` can start a turn in the same tick as the old one ends.
  In `finalizing`, `turn-ended!` would then call `start-turn!` over the live coroutine; in `closing`, the run exits with that turn orphaned.
  No in-tree caller passes `start-if-idle?`, so this was not probed.
- A rejection with no `ref` (malformed, or out of order) never clears an `unacked` entry.
  If a parent's control write fails part-way (`channel.send!` pcalls `f:write` after `next!` already advanced the seq), the torn line and the next control merge into one malformed line.
  That control stays unacked forever, so `idle?` never holds and the parent never sends `close`; the run waits for the deadline (45 min by default).
  This needs a short write (disk full) and was not probed.
- `final-text-path` is trusted: the parent `os.remove`s whatever path the child names.
  The child is fen itself, but the field is wire input.
  Parent-named spill files (#667's fix) would also remove that trust.

## Core

The essential contract is small.
A run is one state from one shared table.
Each control is answered once, then either takes effect or is reported dropped.
`result` comes at most once, immediately before `exit`.
Today "answered once" fails at exactly the moment the run ends: the last batch, after `exit`, and after the parent stops reading.
"Reported dropped" also relies on matching queued text, which is fragile.
Making the ledger explicit on both sides fixes #664 and #666 together.
Queue items carry their `ref`, and the parent settles every control it sent as `injected`, `rejected`, `dropped`, or "unanswered at exit".
#665 shows that state-relative controls (`finalize`, and `close`) race the child's own transitions.
Having a control name the turn it targets would make every control idempotent against the mirror's lag, and would let the parent drop its "only when the mirror says X" guards.
