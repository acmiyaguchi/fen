# TUI turn ownership

Model: [`model.qnt`](model.qnt).
Scope: who owns a turn, its keys, and its events in the TUI.
The model has three tabs: `main` (the interactive session), `side` (the `/btw` singleton), and `sub` (one retained subagent run).
It covers focus switches by key and by mouse, per-tab turn status, the Ctrl-C ladder, the busy-row hint, tab close, Enter while busy (steering queue, side "busy" error, `Steer>`), events from background turns while another tab is focused, and `/reload`.
The presenter state is one record; every key, click, bus event, and tick is one action.
`ctrlCEffect`, `busyHint`, and `busyRowVisible` are pure functions of that record, so the Ctrl-C properties are state invariants.

Code: `extensions/adapters/presenters/tui/{input,workspaces,side_chat,init}.fnl`, `extensions/adapters/presenters/tui/panels/busy.fnl`, `extensions/behaviors/kernel/steering/service.fnl`, `packages/core/src/fen/core/agent.fnl` (`step`, `step-loop`, `inject-after-natural-stop!`), `packages/fen/src/fen/{interactive,turn_submit}.fnl`.
Streaming rows on retry, error, and cancel are covered in [network](../network/FINDINGS.md) and are not repeated here.

## Input assumptions

What the environment actions can produce: any interleaving of keys (type, Enter, Ctrl-C, Alt-arrow, Ctrl-W), tab clicks, `/btw`, the main turn emitting and finishing `ok` or `error` (a cancel request turns the finish into `cancelled`), the side turn emitting and finishing, a closed side turn being reaped, one subagent run starting, emitting and finishing, and `/reload` at idle.
Closing the btw tab chooses the fast path (the turn unwinds within 8 resumes) or the slow one (it is parked).

What they cannot produce: more than 3 main turns, 3 btw generations, or 3 steering lines per trace; more than one subagent run; a draft's content beyond empty/non-empty; a cancel request that a turn ignores (except by taking the slow close path); key-repeat timing; mouse events other than tab clicks.

## Bugs

### #660: Ctrl-C on a side or subagent tab cancels, then force-quits, the hidden main turn

Counterexamples: `ctrlCActsOnShownTurn` (`type → submitMain → openSide`) and `busyHintTruthful` (`type → submitMain → subStart → focusMouse`).
`handle-key` first calls `workspaces.cancel-active!`.
That only succeeds for a side-chat tab whose turn is running.
Otherwise the key drops into the main-session ladder, which checks the main `is-busy?` no matter which tab is focused.
On an idle `btw` tab or a subagent tab, the first Ctrl-C cancels the main turn the user cannot see, and the second exits fen.
The busy row cannot warn about this.
On an idle `btw` tab there is no busy row.
On a running subagent tab, `cancel-hint` leaves the hint out on purpose ("would not touch that turn"), and `docs/tui.md` promises the same ("omitted on tabs where `ctrl-c` would not cancel that turn").
In both cases Ctrl-C does touch a turn: the main one.
This is a sibling of #433, which fixed only the running-side-chat case.

Witnesses: `reachMainCancelTest`, `reachSideClearDraftTest` ([`witnesses.qnt`](witnesses.qnt)); `reachCancelThenForceQuitMainTest`, `reachSideClearDraftWhileMainRunsTest` ([`ctrl-c`](proofs/ctrl-c/) proof model).
Regression test: `extensions/adapters/presenters/tui/tests/ctrl_c_non_main_tab_preserves_main_turn_test.fnl` (tested on the idle btw tab and on a running subagent tab).

Confirmed with a Busted probe against real `input.handle-key` and `panels/busy.render` (main `is-busy?` stubbed true):

```
PROBE side tab status:	idle	focused:	btw
PROBE busy row on side tab:	<no busy row>
PROBE 1st ctrl-c: quit?	false	main-cancels	1	side draft	side draft
PROBE 2nd ctrl-c: quit?	true
PROBE busy row on subagent tab:	  ⠋ bash
PROBE 1st ctrl-c: quit?	false	main-cancels	1
PROBE busy row after 1st:	  ⠋ bash
PROBE 2nd ctrl-c: quit?	true
```

On the idle side tab, Ctrl-C also does not clear the side draft (`"side draft"` survives) as it would with main idle.

### #661: A quit armed on one tab carries over to another tab after a mouse click

Counterexample (`quitArmOnFocusedTab`): `subStart → arm → focusMouse`.
Every key except Ctrl-C clears `pending-quit?` at the top of `handle-key`, so Alt-arrow switching disarms it.
`handle-mouse` calls `workspaces.activate!` directly and never clears it.
After an idle Ctrl-C on main and a click on the `btw` tab, a Ctrl-C meant to clear the side draft exits fen.
The `clearDraft` branch is skipped because `pending-quit?` is set.

Witnesses: `reachQuitAndMouseDisarmTest` ([`witnesses.qnt`](witnesses.qnt)); `reachMouseDisarmTest` ([`ctrl-c`](proofs/ctrl-c/) proof model).
Regression test: `extensions/adapters/presenters/tui/tests/mouse_switch_disarms_quit_arm_test.fnl` (through the real tabs panel hit regions and `handle-mouse`; the Alt-Right switch is the asserted control).

Confirmed with the same probe (the tabs panel `action-at` stubbed to return the `btw` tab):

```
PROBE arm on main: quit?	false	pending	true
PROBE after mouse switch: focused	btw	pending	true
PROBE ctrl-c on side tab with draft: quit?	true	draft	side draft
PROBE after alt-right: focused	btw	pending	false      (control: keyboard switch disarms)
```

The status row does show "ctrl-c again to quit", so this is minor.
The real problem is that the same switch behaves differently by keyboard and by mouse.

### #662: Steering typed for a turn that errors or is cancelled lands in the next turn, after the new prompt

Counterexample (`steeringReachesItsTurn`): `type → submitMain → type → queueSteer → type → error → submitMain`.
Enter while the main turn is busy queues the line as steering (and shows it as a `:user` row right away).
The agent drains the queue only at `inject-after-natural-stop!` and at the top of each `step-loop` iteration.
The `:error` stop path and the cancel path (`CANCEL-MARKER` caught in `step`) return without draining.
Ctrl-C does not clear the queue either.
The line then sits in the queue until the next prompt.
`step` appends that prompt first, then `step-loop` injects the stale correction after it, so the model reads the old correction as the newest instruction.
Nothing is lost (`noSteeringLost` holds); it is delivered to the wrong turn, in the wrong order.

Witnesses: `reachSteeringHandedBackTest`, `reachSteeringDeliveredTest` ([`witnesses.qnt`](witnesses.qnt)); `reachHandedBackTest`, `reachDeliveredMidTurnTest` ([`steering`](proofs/steering/) proof model).
Regression test: `extensions/behaviors/kernel/steering/tests/failed_turn_steering_returned_test.fnl` (on the error and the cancel path).

Confirmed with a probe driving real `agent.step` (mock provider) with the real `steering.service` queue; the correction is typed at the first `:llm-start`:

```
error path:   PROBE turn1 -> [error] boom   PROBE queued after turn1: 1
  1 user fix the parser / 2 assistant error / 3 user now write the docs / 4 user also add tests / 5 assistant ...
cancel path:  PROBE turn1 -> [cancelled]    PROBE queued after cancel: 1
  1 user fix the parser / 2 assistant aborted / 3 user now write the docs / 4 user also add tests / 5 assistant stop
```

This sits on the TUI and agent-loop boundary.
If the agent-loop domain reports it too, treat this as the same bug.

### #663: Reopening `/btw` while a closed tab's turn is still being reaped mixes the two conversations

Counterexamples: `sideEntryOwned` (`openSide → type → submitSide → closeSideSlow → openSide`) and `eventsInOwnTab` (… `closeSideSlow → openSide → sideFinish`).
`side-chat.cancel!` gets 8 resumes to unwind the turn (`CANCEL-RESUME-LIMIT`).
If the turn needs more, it is parked for reaping, but it stays in `volatile.live[:btw]` with `discard? true`.
The new tab has the same id, so `entry-for!` takes over that old entry, because the module owner (`OWNER`) has not changed.
Then:

1. The new tab shows `idle`, but every submit fails with "side agent is busy" until the reap finishes.
2. The old turn's events, including its final reply, go through `on-event! WORKSPACE-ID`, which routes by id, so they land in the new tab's transcript.

Witnesses: `reachReopenWhileReapingTest`, `reachSideTurnCompletesTest` ([`witnesses.qnt`](witnesses.qnt)); `reachReopenWhileReapingTest`, `reachReapFinishesTest` ([`side-ownership`](proofs/side-ownership/) proof model).
Regression test: `extensions/adapters/presenters/tui/tests/reopened_btw_isolated_from_reaped_turn_test.fnl`.

Confirmed with a probe on real `side_chat.fnl`, using a fake `agent.step` that needs 12 yields to unwind:

```
PROBE old status	running
PROBE after close: tab present?	false	old.status	closed
PROBE reopened: new==old?	false	new.status	idle	new.side.busy?	false
PROBE submit new question -> ok	false	error	side agent is busy
PROBE new tab transcript:
PROBE   	assistant-text	late reply to: old question
PROBE submit after reap -> ok	true	error	nil
```

How often this happens: the real `agent.step` raises `CANCEL-MARKER` at the first resume after a cancel request, so a normal turn unwinds in fewer than 8 resumes.
The bug needs a turn that takes longer to unwind, which is exactly the case the park-for-reap path exists for (#441).

## Holds

Evidence: sampled (`check-spec`); `draftsPreserved`, `noSteeringLost`, `closedSideCancelled`, and `closedSideIdle` are also inductive in the proof models below (for the fixed design; `draftsPreserved` for today's).

- `noSteeringLost`: every line typed while busy is delivered, still queued, or handed back. A side-chat Enter while busy and a `Steer>` submit that fails both keep the draft.
- `closedSideCancelled`, `closedSideIdle`: closing the `btw` tab always asks its turn to cancel, and the tab stays non-running.
- `draftsPreserved`: per-tab drafts survive key and mouse switches, other tabs' turns, close, and `/reload`. `activate!`/`with-view!` save and load all view keys, and after a reload `ensure!` only fills fields that are missing.
- By design, not a bug: closing a subagent tab only hides it, and the run continues (`docs/tui.md`). `/reload` cancels a running side turn (#441). The workspace and transcript survive.
- Main-session events always go through `with-main!`, so they land in the main tab whatever is focused. Subagent events go only to their own tab, and a closed tab is not recreated.

## Open questions

- Which real turns take more than 8 resumes to unwind after a cancel request (#663's precondition)? Candidates are tools that `pcall` around the yield function, and parallel tool tasks in nested coroutines. None has been shown yet.
- While a closed side turn is being reaped, `side-chat.busy?` is false, so `peek-timeout-ms` uses the long idle poll and the reap advances slowly. This is a latency concern only and was not probed.
- `guard-tick!` errors from `side-chat.tick!` go out on the bus, so they land in the main transcript, not the `btw` tab. That is arguably right for a presenter fault. Not modelled.

## Fixed in #605

All of #660–#663 are fixed in the code, and `current` now enables the fixes, so its former `violated` rows are `holds`.
The counterexample witnesses became `reach...Test` traces on the fixed design.

- Ctrl-C on non-main tabs (#660): `input.fnl` restricts the main session's cancel/force-quit ladder to the main tab; other tabs cancel their own turn or clear local drafts / run the two-press quit without touching the main turn.
- Mouse switch disarms quit arm (#661): `workspaces.activate!` disarms `state.pending-quit?`, so mouse switches match keyboard switches.
- Steering handed back at turn end (#662): steering lives in the core turn mailbox (`fen.core.tasks`), tagged with its turn; `turn_submit` closes the turn inside its coroutine and every turn end (ok, error, or cancel) returns the unread lines as `:steering-returned`, which the TUI puts back in the main draft (spec/core/tasks `requestsSpec`).
- Reopened `/btw` isolated from reaped turn (#663): `side_chat.fnl` removes parked entries from `live` into `reap`, captures `ws` in event callbacks and drops events for closed tabs, and reflects `reap` in `busy?`.

Side turn cancel is fenced like the main holder (`spec/core/tasks/proofs/fence`).
The live entry is the turn's fence (`fen.util.cancel_fence`): `turn_submit`'s `spawn-plain!` acquires a fresh id per turn and the turn polls `cancel-requested? entry hid`; `request-cancel!`, `cancel!`, the reload takeover, and `reset!` cancel the id holding at that moment, and `finish-turn!` releases it.
The workspace-level `ws.side.cancel-requested?` flag is gone; `side-chat.cancel-requested? ws` reads the live entry.
The side-ownership model's entry `cancel` bit is that fence's armed bit for the entry's generation.
Regression test: `side_chat_test.fnl` ("a late cancel for side turn 1 never cancels side turn 2").

## Candidate fixes (named: `FIXES`)

The model takes `const FIXES: Set[str]`; `current` enables none, `fixed` all four, and `fix660` … `fix663` one each, with `checks.tsv` rows showing each fix makes its own issue's invariants hold (sampled).

- #660: the main cancel/force-quit ladder applies only when the main tab is focused. Other tabs either cancel their own turn through the kind's `cancel!` or fall through to clear-draft and the two-press quit. The hint then matches the action.
- #661: `workspaces.activate!` clears `pending-quit?`, so every focus path disarms it.
- #662: when a turn ends by error or cancel, its queued steering lines are handed back (for example restored to the main draft or shown as an info row), not left for the next turn.
- #663: `cancel!`'s slow path removes the entry from `volatile.live` into the reap list. Each turn routes events to the tab generation that started it (capture the workspace record or a turn token, not `WORKSPACE-ID`), and events for a closed tab are dropped.

All invariants hold under `fixed` (sampled).
Reachability witnesses show the fixed design still cancels and force-quits the main turn from the main tab, clears the side draft on an idle btw tab while main runs, cancels a running side turn from its tab, keeps the two-press quit (and a click disarms it), hands back steering of an errored turn and delivers it at a natural stop, and gives a usable reopened btw tab while the old turn is reaped.

Mutants ([`mutants.tsv`](mutants.tsv)), each caught: the main ladder on every tab again (`ctrlCActsOnShownTurn`, `busyHintTruthful`), the mouse path without the disarm (`quitArmOnFocusedTab`), a failed turn's steering left queued (`steeringReachesItsTurn`), and the slow close parking the turn in `live[:btw]` (`sideEntryOwned`).
In the side-ownership proof model two more show both halves of the #663 fix are needed: the reap list without generation routing lets the reaped turn's reply into the reopened tab, and routing without the reap list leaves the reopened tab blocked.
The drafts proof model's mutants drop the view save on `activate!` and on `/btw`.

## Proof models

One per contract under [`proofs/`](proofs/), without transcripts: ownership is checked by generation identity plus a sticky bad-delivery monitor, and drafts need only the views. Verified with `verify-spec` (Apalache 0.56.1, one lane, `-Xmx3g`, shared machine):

| Model | Issues | State | Obligation | Result | Time |
| --- | --- | --- | --- | --- | --- |
| [`ctrl-c`](proofs/ctrl-c/model.qnt) | #660, #661 | focus, open tabs, which turns run, a draft flag per tab, the main ladder (cancel-pressed?, pending-quit?, armed-on tab) | `fixed.ctrlCInductive` | inductive | 4 s |
| [`side-ownership`](proofs/side-ownership/model.qnt) | #663 | btw tab generation, live entry (present, generation, cancel), one reaped turn and its generation, bad-delivery monitor | `fixed.ownershipInductive` | inductive | 1 s |
| [`steering`](proofs/steering/model.qnt) | #662 | main turn number and busy flag, queue as (length, owner turn), typed/delivered/returned counters, misdelivery monitor | `fixed.steeringInductive` | inductive | 1 s |
| [`drafts`](proofs/drafts/model.qnt) | none (holds today) | focus, open tabs, the focused view, each tab's saved draft and a ghost of the intended one | `drafts.draftsInductive` | inductive | 2 s |

`ctrl-c` also has `fix660` and `fix661` instances. The side-ownership model assumes at most one closed turn is reaped at a time.

## Core

All four bugs have one cause: the code resolves "the current turn" through a global at the time of use, not through the owner recorded when the turn started.
In #660 that global is `is-busy?` and `cancel-pressed?`, in #661 `pending-quit?`, in #662 the steering queue, and in #663 the `:btw` id.
A pure TUI core `(state, event) -> (state', effects)` needs very little:

- a tab table where each tab holds `{kind, view, turn: {id, status, cancel-armed?}}`, plus `focus`;
- events tagged with `turn-id` and folded only into the tab that owns that turn (unknown or retired ids are dropped);
- Ctrl-C defined as `f(focused tab's turn)`, returning one effect (`cancel(turn-id)`, `clear-draft`, `arm-quit`, or `quit`); the busy hint is the same function shown as text;
- a steering queue keyed by `turn-id`, so a turn that ends hands its own queue back (done: `fen.core.tasks`).

Then main, side, and subagent differ only in kind policy, meaning which effects their turn accepts.
The model suggests moving the main session's `cancel-pressed?` and `status-info` into the main tab's turn record.
That would make the main tab one more workspace and remove the special case in `handle-key`.
