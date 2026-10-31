# Cooperative scheduler (TUI presenter loop)

Model: [`model.qnt`](model.qnt).
Scope: the loop that drives every coroutine in an interactive fen process.
One `iteration` is one pass of `M.run`: paint, `tb.peek_event` with `peek-timeout-ms`, input under xpcall (the Ctrl-C ladder), `on-tick` under xpcall (`:runtime-tick` handlers, one resume of the main turn, finalization, then the idle boundary: deferred reload drain, idle follow-up), `tick-background!` (side chat, subagent projection), and the bottom-of-loop `cancel-pressed?` reset.
`modalPump` is the select overlay's own loop (`select.fnl` `pump-background-ticks!`), which pumps `on-tick` and `tick-background!` every 30 ms without the rest of `M.run`.
The environment can emit a transcript row that cannot be rendered, queue a reload from inside the agent turn (the `reload` tool), start a decide `ask-async!` task, and submit or cancel the side chat. A completed `/reload` turn bumps the module generation, and the side-chat owner check then cancels and reaps the previous generation's turn.
Coroutines yield, finish, or error. Agent turns observe a cancel at the first resume after the request. `/reload` turns never observe one.

Code: `extensions/adapters/presenters/tui/init.fnl` (`M.run`, `peek-timeout-ms`, `guard-tick!`, `tick-background!`, `warn-if-stalled!`), `extensions/adapters/presenters/tui/paint.fnl` (`redraw-if-needed!`, `paint-frame!`, `paint-panels`), `extensions/adapters/presenters/tui/panels/transcript.fnl` (`render-lines-for-event`, `wrap-text`), `extensions/adapters/presenters/tui/input.fnl` (Ctrl-C ladder), `extensions/adapters/presenters/tui/select.fnl` (`run-overlay`), `extensions/adapters/presenters/tui/side_chat.fnl` (`tick!`, `resume-entry!`, reap), `packages/fen/src/fen/interactive.fnl` (`on-tick`, presenter xpcall and shutdown), `packages/fen/src/fen/{turn_submit,reload_request}.fnl`, `packages/core/src/fen/core/agent.fnl` (`make-yield`), `packages/core/src/fen/core/extensions/events.fnl` (per-handler xpcall), `extensions/behaviors/kernel/decide/service.fnl` (`ask-async!`, `pump!`), `extensions/behaviors/actions/sessions/commands/session.fnl` (`start-reload!`, `reload` tool).
Streaming rows, turn ownership across tabs, and the tool-side yield contract belong to [network](../network/FINDINGS.md), [tui-turns](../tui-turns/FINDINGS.md), and `spec/tools`. They are not repeated here.

## Input assumptions

What the environment actions can produce:

- Any interleaving of whole pumps (`iterate`, one pass of `M.run`; `pumpModal`, one select-overlay pump) with the environment actions: a bad row, a reload request queued from inside an agent turn, a runtime-tick task (at most 2 live), a side-chat submit or cancel.
- Inside a pump, each coroutine's resume outcome is any of yield, finish, error; the key read by the poll is none, Ctrl-C, or Enter; at the idle boundary a next turn may or may not be started (goal continuation, idle follow-up).
- At most 4 main turns per trace (`MAX_TURNS`).

What they cannot produce:

- A pump interrupted part-way: the phases of one pass are one atomic step, in the code's order (paint, poll, input, on-tick, background, bottom). #636 depends on that order (input before on-tick before the bottom reset), and the model keeps it.
- Nested `on-tick` from inside the main turn (see Open questions), a `tb_peek_event` failure, or real time: the poll wait is recorded, not slept.
- Fairness: nothing forces pumps to run or environment actions to stop. No property here is a liveness property.

## Bugs

### #635: A transcript row that fails to render ends the session

Counterexample (`loopSurvivesFaults`): `emitBadRow → iteration`.
#416/#432 fixed this class of bug for the side-chat and subagent ticks.
Today every loop phase is isolated except paint.
`on-tick`, input, `side-chat.tick!`, `sync-subagents!`, each bus handler, each status item, and each panel slot run under `xpcall`/`pcall`.
`paint.redraw-if-needed!` is called bare at the top of `M.run`, and inside it `paint-transcript` and `paint-input` are not guarded.
Ingest accepts any event into `state.transcript`.
A field the renderer cannot handle (a non-string `:text`, for example) then raises on the next frame.
The error leaves `M.run`, `interactive.fnl`'s xpcall runs presenter shutdown, which restores the terminal correctly, and the process exits with `presenter crashed`.
The in-flight turn, side chat, and background subagent jobs all go with it.

Witnesses: `w635BadRowCrashesLoopTest` ([`witnesses.qnt`](witnesses.qnt)) and the [`pump`](proofs/pump/) proof model's `w635BadRowCrashesLoopTest`.
Probe: `extensions/adapters/presenters/tui/tests/issue_635_unguarded_paint_test.fnl` (reproduces; a well-formed row is the control).

Confirmed (counterexample, then a Busted probe): real `events.emit` into the real TUI subscriber, then the real `M.run` with the termbox stub (`tb-initialized? true`, peeks scripted to no-event):

```
(events.emit {:type :info :text 42})
PROBE D1 transcript rows after emit  1  last type  info
PROBE D1 run returned ok?  false  ticks  0
      err  extensions/adapters/presenters/tui/panels/transcript.fnl:167: attempt to get length of a number value (local 's')
```

No first-party emitter of a malformed row was found, so the trigger today is any extension's `api.emit` or a future core event.
The bug is the missing isolation: one bad row is fatal, while a bad status item or panel only prints `panel-error:`.

### #636: The Ctrl-C arm outlives its turn, so the next turn's first Ctrl-C force-quits fen

Counterexamples: `cancelArmMatchesTurn` (`submit → agentQueuesReload → ctrlC`) and `forceQuitOnlyOnArmedTurn` (`… → ctrlC → ctrlC`).
The first busy Ctrl-C sets `state.cancel-pressed?`.
`M.run` clears it only at the bottom of an iteration, and only if `(is-busy?)` is false at that moment.
That is a check on the busy *level*, but the arm belongs to a turn *identity*.
`on-tick` can end turn A and start turn B in the same call.
When the dead turn leaves a queued reload request (the agent called the `reload` tool), `reload-request.drain!` starts a `/reload` turn.
A goal continuation started from `:agent-turn-complete`, or an `api.enqueue` idle follow-up, does the same.
By the bottom check `is-busy?` is true again, so the arm survives into B.
The busy row then reads `ctrl-c again quit` for a turn the user never cancelled, and the next Ctrl-C exits fen in the middle of the `/reload` module swap.
The select modal's pump also finalizes turns without ever reaching the bottom check, so it is a second path to the same state.
(The `rpc` child presenter tracks turns by coroutine identity, `ch.state.turn ≠ ch.active.co`, and does not have this bug.)

Witnesses: `w636ArmOutlivesTurnTest`, `w636NextCtrlCForceQuitsTest`, and in the [`cancel-arm`](proofs/cancel-arm/) proof model also `w636ModalPumpPathTest` (the select-overlay path: Ctrl-C arms on a `/reload` turn, the overlay's pump finishes it and starts a goal continuation, and no bottom reset runs).
Probe: `extensions/adapters/presenters/tui/tests/issue_636_cancel_arm_outlives_turn_test.fnl` (reproduces; the run without a queued reload is the asserted control). Its `on-tick` is a copy of `interactive.fnl`'s order, since the real one cannot be driven in-process.

Confirmed with a probe: the real `M.run`, the real `input.handle-event` Ctrl-C ladder, and the real `reload_request.enqueue!`/`drain!`, with an `on-tick` that copies `interactive.fnl`'s order (resume → on death clear `busy?`/`turn` → drain reload at the idle boundary) and an agent-like turn that raises on cancel at resume. Peeks: `none, Ctrl-C, none, Ctrl-C`:

```
PROBE D2 control         peeks consumed 5 (ran to end)  turn-id 1 busy? false cancel-pressed? false pending-quit? true
PROBE D2 reload-queued   peeks consumed 4 (QUIT early)  turn-id 2 busy? true  cancel-pressed? true  pending-quit? false
```

Without a queued reload, the second Ctrl-C (now idle) only arms the two-press quit.
With one queued, the second Ctrl-C lands on the fresh `/reload` turn (turn-id 2) and quits.

### #637: Pending cooperative work outside the main and side turns is polled at the idle cadence

Counterexample (`pendingWorkPolledActively`): `startBgTask → iteration`.
`peek-timeout-ms` treats only the main turn, the side chat, dirty/spinner state, and a pending Esc as active work.
`:runtime-tick` handlers resume their own coroutines once per `on-tick`: decide `ask-async!` tasks, the codex usage `refresh-co`, and subagent job pumps.
`docs/tui.md` says "active cooperative work is polled every 30 ms", but these tasks get one resume per 300 ms whenever the main turn is idle.
A decide request drives `fen_http` cooperatively: each resume runs at most one ≤50 ms `curl_multi_poll` plus one body slice, then yields.
An idle-time ask (an auto-compaction moment, or a durable-preference hint that resolves after the turn has ended) therefore advances at roughly 1/7 of its network speed.
The side-chat reap list (the open question in tui-turns) is the same blind spot: `side-chat.busy?` is false while a parked turn is still being reaped.

Witnesses: `w637IdlePollForPendingTaskTest` (integration and [`pump`](proofs/pump/) models).
Probe: `extensions/adapters/presenters/tui/tests/issue_637_idle_poll_pending_task_test.fnl` (reproduces: four peeks with a pending decide task, all 300 ms; the busy main turn's 30 ms is the control).

Confirmed with a probe: the real `M.run` (`tb-initialized? true`), the real decide `service.pump!` subscribed to `:runtime-tick`, and a real decide task that needs 4 resumes:

```
PROBE D3 pending decide task; peek timeouts  300,300,300,300,300,300,300
PROBE D3 resumes 4  task finished after resume 4  tasks left 0
PROBE D3 control: main busy -> peek 30
```

This costs latency, not correctness.

## Holds

Evidence: sampled (`check-spec`) unless a proof model below says otherwise.

- `terminalRestoredWhenStopped`: each way the loop can stop (Ctrl-D, the force-quit ladder, a `tb_peek_event` failure, or a crash out of `M.run`) passes through `presenter-registry.shutdown-active-presenter` → `M.shutdown`. If the presenter slot was lost, `interactive.fnl` falls back to a raw `termbox2.shutdown`. Bracketed paste and the log sink are restored too.
- `runnableResumedEachPump` (was `noStarvation`): each pump resumes the main turn once, each live side turn once, and each runtime-tick task once, and `tick-background!`'s nesting guard prevents re-entry from a modal opened by a background turn. This is a per-pump safety bound, not a scheduling guarantee: the wait counters are bumped by the pump itself (`age`) and reset by the resume in the same pump, so they say nothing about how often pumps run. No liveness is claimed ("every runnable task is eventually resumed" would need a fairness assumption on pumps, which no model states).
- `cancelledTurnEndsInPump` (was `cancelObservedWithinOneTick`): an agent turn whose cancel was requested before or during a pump's input phase has ended when that pump finishes, because `make-yield` checks after `coroutine.yield` returns and `on-tick` runs after input. Again a per-pump bound, not "eventually". The exception is the `/reload` turn, whose plain `coroutine.yield` never checks. This is by design (reload is atomic), but see the open questions.
- `busyMatchesAlive`, `noDeadResume`: `state.busy?` and `state.turn` are set together in `turn_submit.start!`/`start-reload!` and cleared together in `on-tick`'s death path. `on-tick` resumes only `state.turn`. `side_chat.resume-entry!` checks `coroutine.status` first. Decide drops dead tasks, and codex usage nils `refresh-co` once it is dead. Nothing resumes a finished coroutine.
- `noStaleSideAdvanced`: after `/reload` swaps `side_chat`'s `OWNER`, `tick-one!` never resumes the old entry as live. It requests a cancel and moves the entry to the reap path (#441).
- Errors in `:runtime-tick` handlers, the main turn (`agent task: …`), `side-chat.tick!`, `sync-subagents!`, and input all become `:error` events and the loop continues. `guard-tick!`'s own error path cannot throw, because `events.emit` xpcalls every handler, so `background-ticking?` cannot stick at `true`.
- Input is not lost while busy. Every iteration polls termbox before ticking. `drain-scroll-burst!` handles the first non-scroll event after a burst. Keys buffered behind a slow tick are read on the next pass. (Not modelled; checked line by line.)

## Open questions

- **Nested `on-tick` from inside the main turn.** `select.fnl`'s pump calls `state.on-tick` with no re-entry guard, unlike `tick-background!`. If anything running *inside* the main turn opened `api.ui.select` (an extension tool, say), `coroutine.resume state.turn` would see a running coroutine and return `false, "cannot resume non-suspended coroutine"`. `on-tick` would then report `agent task: …`, clear `busy?`/`turn`, and emit `:agent-turn-complete` while the turn is still running. When the turn next yields, the outer `on-tick` calls `coroutine.status` on `nil` and the turn is orphaned. Today every `ui.select` caller is a slash command dispatched from input on the main stack, so this is not reachable from first-party code, and it was not probed.
- **Ctrl-C during `/reload`.** The first press arms the ladder and shows `cancelling…`, but the reload ignores it. The second press force-quits in the middle of a module swap. The documented escape hatch makes this defensible, but the hint promises a cancel that cannot happen.
- **`reload_request.drain!` writes failures with `io.stderr:write`.** While termbox owns the screen this bypasses the b48b10b log sink and corrupts the frame. It is only reachable if the `/reload` dispatch prelude throws.
- **`warn-if-stalled!` only knows the main coroutine** (`?get-turn`). A stall inside a side-chat resume or a runtime-tick task is logged as `phase=tick` with the main turn's stack, or none. Diagnostics would point at the wrong coroutine.

## Candidate fixes (named: `FIXES`)

The model takes `const FIXES: Set[str]`. `current` enables none, `fixed` all three, and `fix635`, `fix636`, `fix637` one each; `checks.tsv` shows each fix makes its own issue's invariants hold (sampled).

- #635: run the paint phase under the same guard as the ticks. Better, give `paint-transcript` per-row isolation, as `paint-panels` already has, so a bad row renders as `render-error:` and the frame continues.
- #636: disarm the ladder where the turn is finalized (`on-tick`'s death path, or the TUI's `:agent-turn-complete` handler), not at the loop bottom. Equivalently, key the arm by turn id (`pressGen == state.turn-id`). Then the modal pump and same-tick turn starts are covered too, and the bottom check can be deleted.
- #637: let runtime-tick sources report pending work. One way is a `busy?` query on the scheduler's task registry (decide tasks, `refresh-co`, live subagent jobs, the side-chat reap list) that `peek-timeout-ms` ORs in.

All invariants hold under `fixed` (`fixed.allInvariants`, sampled).
Reachability witnesses (`reach...Test`) show the fixed design still completes, cancels, starts the `/reload` turn in the same tick (now disarmed), force-quits a turn on its own second press, survives a bad row with the turn still running, finishes a background task at the active cadence, and finalizes a turn from the modal pump beside a side turn.

Mutants ([`mutants.tsv`](mutants.tsv)), each caught by `check-spec`: unguarded paint (`fixed.loopSurvivesFaults`), runtime-tick tasks ignored by the poll (`fixed.pendingWorkPolledActively`), the finalize-time disarm removed so only the bottom check remains (`fixed.cancelArmMatchesTurn`, via the modal pump), and the main resume no longer resetting its wait counter (`current.runnableResumedEachPump`, so the per-pump bound is not vacuous).

## Proof models

Small models of single contracts under [`proofs/`](proofs/), checked by `verify-spec` (Apalache 0.56.1, one lane, `-Xmx3g`, on a shared, loaded machine):

| Model | State | Obligation | Result | Time |
| --- | --- | --- | --- | --- |
| [`cancel-arm`](proofs/cancel-arm/model.qnt) (#636) | turn kind and generation, cancel request, queued reload, the arm and its generation; phases in the code's order, plus the modal pump | `fixed.armInductive` | inductive | 8–12 s |
| | | `fixed.cancelArmMatchesTurn forceQuitOnlyOnArmedTurn`, 5 steps | bounded-safe (cross-check at the counterexample length) | 29–114 s (machine load) |
| [`pump`](proofs/pump/model.qnt) (#635, #637) | loop, terminal, bad row, pending main/side/runtime-tick work, last poll wait | `fixed.pumpInductive` | inductive | 2 s |

Both also have a `current` instance whose `checks.tsv` rows are `violated` with witnesses, so the bugs are counterexamples there too.

## Core

Underneath, the loop is a round-robin scheduler with no task table.
Today it has five ad hoc task registries: `state.turn` (interactive run-state), side chat's `volatile.live` and `volatile.reap`, decide's `store.tasks`, codex usage's `refresh-co`, and the subagent job list.
Three different drivers resume them (`on-tick`, `tick-background!`, `:runtime-tick` handlers), and the select modal re-implements the driver.
Each registry has its own resume/finish/error code, and the loop learns "is anything runnable?" and "did this turn end?" by asking a few of them for a boolean.
All three bugs come from that: paint is the one phase not routed through the common guard (#635), turn end is inferred from a level rather than an identity (#636), and runnable work that isn't in the two known registries is invisible to the poll timeout (#637).

The minimal core is a single cooperative task table, `{id, owner, co, cancel?, on-done}`, with one driver step: resume each live task once under xpcall, retire dead ones exactly once by calling `on-done(ok, value)`, and report `any-runnable?`.
The presenter loop then becomes `paint (guarded) → poll(any-runnable? ? 30 : 300) → input (guarded) → scheduler.step → idle hooks`, and the modal calls the same `scheduler.step`.
The main turn, side turns, reaps, decide asks, and usage refresh all become entries in that table, and each turn's UI state (cancel arm, busy row) is keyed by task id.
What could be deleted: `tick-background!` and its `background-ticking?` guard, `side_chat.resume-entry!`/`reap-entry!` (one bounded-resume helper in the table instead), decide's `pump!`, the codex `refresh-co` pump, `select.fnl`'s `pump-background-ticks!`, the bottom-of-loop `cancel-pressed?` reset, and the hand-maintained OR in `peek-timeout-ms`.
