# TUI turn ownership

Model: [`model.qnt`](model.qnt).
Scope: who owns a turn, its keys, and its events in the TUI.
The model has three tabs: `main` (the interactive session), `side` (the `/btw` singleton), and `sub` (one retained subagent run).
It covers focus switches by key and by mouse, per-tab turn status, the Ctrl-C ladder, the busy-row hint, tab close, Enter while busy (steering queue, side "busy" error, `Steer>`), events from background turns while another tab is focused, and `/reload`.
The presenter state is one record; every key, click, bus event, and tick is one action.
`ctrlCEffect`, `busyHint`, and `busyRowVisible` are pure functions of that record, so the Ctrl-C properties are state invariants.

Code: `extensions/adapters/presenters/tui/{input,workspaces,side_chat,init}.fnl`, `extensions/adapters/presenters/tui/panels/busy.fnl`, `extensions/behaviors/kernel/steering/service.fnl`, `packages/core/src/fen/core/agent.fnl` (`step`, `step-loop`, `inject-after-natural-stop!`), `packages/fen/src/fen/{interactive,turn_submit}.fnl`.
Streaming rows on retry, error, and cancel are covered in [network](../network/FINDINGS.md) and are not repeated here.

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

- `noSteeringLost`: every line typed while busy is delivered, still queued, or handed back. A side-chat Enter while busy and a `Steer>` submit that fails both keep the draft.
- `closedSideCancelled`, `closedSideIdle`: closing the `btw` tab always asks its turn to cancel, and the tab stays non-running.
- `draftsPreserved`: per-tab drafts survive key and mouse switches, other tabs' turns, close, and `/reload`. `activate!`/`with-view!` save and load all view keys, and after a reload `ensure!` only fills fields that are missing.
- By design, not a bug: closing a subagent tab only hides it, and the run continues (`docs/tui.md`). `/reload` cancels a running side turn (#441). The workspace and transcript survive.
- Main-session events always go through `with-main!`, so they land in the main tab whatever is focused. Subagent events go only to their own tab, and a closed tab is not recreated.

## Open questions

- Which real turns take more than 8 resumes to unwind after a cancel request (#663's precondition)? Candidates are tools that `pcall` around the yield function, and parallel tool tasks in nested coroutines. None has been shown yet.
- While a closed side turn is being reaped, `side-chat.busy?` is false, so `peek-timeout-ms` uses the long idle poll and the reap advances slowly. This is a latency concern only and was not probed.
- `guard-tick!` errors from `side-chat.tick!` go out on the bus, so they land in the main transcript, not the `btw` tab. That is arguably right for a presenter fault. Not modelled.

## Candidate fix (modelled as `fixed`)

- #660: the main cancel/force-quit ladder applies only when the main tab is focused. Other tabs either cancel their own turn through the kind's `cancel!` or fall through to clear-draft and the two-press quit. The hint then matches the action.
- #661: `workspaces.activate!` clears `pending-quit?`, so every focus path disarms it.
- #662: when a turn ends by error or cancel, its queued steering lines are handed back (for example restored to the main draft or shown as an info row), not left for the next turn.
- #663: `cancel!`'s slow path removes the entry from `volatile.live` into the reap list. Each turn routes events to the tab generation that started it (capture the workspace record or a turn token, not `WORKSPACE-ID`), and events for a closed tab are dropped.

All invariants hold under `fixed`.

## Core

All four bugs have one cause: the code resolves "the current turn" through a global at the time of use, not through the owner recorded when the turn started.
In #660 that global is `is-busy?` and `cancel-pressed?`, in #661 `pending-quit?`, in #662 the steering queue, and in #663 the `:btw` id.
A pure TUI core `(state, event) -> (state', effects)` needs very little:

- a tab table where each tab holds `{kind, view, turn: {id, status, cancel-armed?}}`, plus `focus`;
- events tagged with `turn-id` and folded only into the tab that owns that turn (unknown or retired ids are dropped);
- Ctrl-C defined as `f(focused tab's turn)`, returning one effect (`cancel(turn-id)`, `clear-draft`, `arm-quit`, or `quit`); the busy hint is the same function shown as text;
- a steering queue keyed by `turn-id`, so a turn that ends hands its own queue back.

Then main, side, and subagent differ only in kind policy, meaning which effects their turn accepts.
The model suggests moving the main session's `cancel-pressed?` and `status-info` into the main tab's turn record.
That would make the main tab one more workspace and remove the special case in `handle-key`.
