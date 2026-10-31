# Attachable fen: serve, remote input, async UI (design-first)

Integration model: [`model.qnt`](model.qnt), with [`witnesses.qnt`](witnesses.qnt) and [`mutants.tsv`](mutants.tsv).
Proof models: [`proofs/controls`](proofs/controls/model.qnt), [`proofs/requests`](proofs/requests/model.qnt), [`proofs/replay`](proofs/replay/model.qnt) (see [Proof models](#proof-models)).

## Scope

This domain covers features that are mostly unbuilt.
The aim is to find bugs in the proposed designs while they are cheap to fix, and to write down what the protocol must guarantee before implementation starts.

The model has one fen process with one agent loop, one in-process presenter (client 0, the TUI), and two remote serve clients (1 and 2).
The TUI is an `api.on :*` subscriber, so it sees every bus event at once.
Remote clients see events only when the stream delivers them, so their view of "which turn is running" lags.
Remote clients connect, disconnect, and reconnect (with or without a resume point).
Any client can send a line (a prompt if it sees idle, steering if it sees a turn), cancel the turn it sees, and answer any request it has seen.
The agent can issue a request from inside a turn (a tool or permission check, which parks the turn) or from an idle-only slash command's picker (`/resume`, `/model`).
The environment can refresh a picker's choices, time a request out, end or cancel the turn, and `/reload`.
A ghost history records, for every cancel, steer, and applied answer, the turn or request the sender aimed at and the one it actually hit.

Not modelled: transport details (HTTP, SSE framing, bearer-token checks), subagent child streams and the session index's descent into them, and process restart (see Open questions).

## Input assumptions

What the environment actions can and cannot produce:

- **One process, one cooperative thread.** Every action is atomic; nothing interleaves inside an action. Two turns never run at once (`singleTurn` checks the model keeps this, not the code).
- **Client views only lag; they never lie.** A remote client's `seenTurn`, known requests, and choice versions come only from events delivered to it (or a snapshot), so a view is always some past state of the process. A client never invents a turn id or a request id it has not seen. The TUI (client 0) sees every event synchronously.
- **Answers name a request the client has seen** (`ever`), possibly one already resolved. An answer's choice is not modelled, only the choice-list version it was made against.
- **The agent issues requests from two places only:** a running turn that is not parked (a tool or permission check, which parks it) and an idle-only slash command (at most one idle-scoped picker pending). At most `MAX_REQS = 3` requests, `MAX_TURNS = 3` turns, `MAX_LOG = 10` events, one choice-list refresh per request.
- **The environment can** end or cancel the turn, refresh an idle picker's choices, `/reload` while idle, time out a request that carries a deadline, and connect, disconnect, reconnect (with or without a resume point), replay, deliver, and overflow the ring for remote clients 1 and 2.
- **It cannot** crash or restart the process, lose or reorder events on a live stream (delivery is in log order by cursor), deliver an event before it is emitted, or have a client answer while it is disconnected or still attaching.
- **No fairness.** Nothing forces a client to answer, a deadline to fire, or a turn to end, so no invariant claims that anything eventually happens (see `pendingHasPossibleResolver`).

The proof models keep these assumptions and drop state each contract does not need; their headers say what each abstracts (for example, the request model lets an answerer hold any choice-list version up to the current one, and the controls model lets a steering line be injected in any order).

Code the designs reuse, and that the model mirrors:
`extensions/adapters/presenters/web/server.fnl` (`wait-select`, `finish-select!`, `/input` → `drain-inputs!`), `extensions/adapters/presenters/web/page.fnl` (`postSelect`), `extensions/adapters/presenters/tui/select.fnl` (`run-overlay`, `pump-background-ticks!`), `packages/core/src/fen/core/extensions/register/presenter.fnl` (`FALLBACKS`, `dispatch-ui`), `packages/core/src/fen/core/extensions/register/command.fnl` (`dispatch`, `:idle-only?`), `extensions/behaviors/kernel/steering/service.fnl` (`queue!`, `submit`, `enqueue!`, `start-idle-follow-up!`), `packages/fen/src/fen/interactive.fnl` (`request-cancel`, `on-submit`, `on-tick`), `packages/fen/src/fen/turn_submit.fnl`, `packages/fen/src/fen/reload_request.fnl`, `packages/fen/src/fen/session_lifecycle.fnl` (flush), `extensions/behaviors/actions/sessions/commands/session.fnl` (`pick-session!`, `/reload`), `extensions/behaviors/kernel/essentials/commands/model.fnl` (`pick-model!`), `docs/wire.md`.

Today's `ui.select` call sites are all slash-command pickers: `/resume` (`session.fnl:168`), `/model` (`model.fnl:168`), skill details (`skills/init.fnl:655`), extension details (`extension.fnl:474`), and the TUI tabs picker (`input.fnl:589`).
No tool and no permission check calls `ui.select` or `ui.prompt` today, so turn-scoped requests are the new case #398 enables (its "subagent escalation", and permission prompts if they are built on it).

## Designs modelled

- **#394** (umbrella): one process, one live session, one event stream; serve is an extension on the events bus and steering queue, with no new hooks, kinds, or queues. "Multi-client select resolution is first-writer-wins with the resolution broadcast."
- **#396** (observer): "replays the current session JSONL on attach before following live", "in chunks with yield callbacks", and should "reuse socket/flush machinery from `extensions/adapters/presenters/web/server.fnl` where it fits".
- **#397** (input): "Inputs inject into the existing steering/follow-up queues; no new queue kinds." "Cancel wired to the same path the TUI uses." "All clients share the queues; resolutions and queue state are broadcast so clients converge."
- **#398** (async UI): "the agent emits `select-requested` with an id and choices, parks on it, and resumes on `select-resolved` from any attached client"; "First-writer-wins across clients; late answers are ignored and the winning resolution broadcast."

Each `const` selects one choice; the instances are:

| Instance | What it is |
| --- | --- |
| `issue` | The four issues as written, with the TUI attached. Replay is the JSONL snapshot, then live from the end of replay (`REPLAY = "jsonlGap"`). |
| `issueDup` | Same, but the yielding replay subscribes to live events first and reads the growing JSONL (`"jsonlDup"`). #396 leaves this ordering open; these are the two ways to implement it. |
| `headless` | `issue` with no in-process presenter that can answer, which is serve beside `rpc`, `json`, `print`, or `goal_headless` (#396: "runs alongside any active presenter"). |
| `webReuse` | `issue` with the web presenter's existing `/select` and `/input` handlers, which #396 says to reuse. |
| `proposed`, `proposedTui` | The recommended protocol (Required guarantees), headless and with the TUI. Every invariant holds. |

`checks.tsv` records the results: `violated` rows are counterexamples in the issue designs, and `holds` rows cover the proposed protocol and the properties the issues already get right.

The serve model has no `FIXED` flag, so the named-fixes convention (`FIXES`, `fix<issue>` instances) does not apply: each design choice is already a named `const`, and the instances are designs, not fix bundles.
`proposed` and `proposedTui` play the part of `fixed`: they must satisfy every invariant, and the `reach...Test` witnesses show they still reach the cases those invariants guard.

## Evidence

| Bug | Kind | Rows | Witness (`witnesses.qnt`) | Proof-model witness | Confirmed against code |
| --- | --- | --- | --- | --- | --- |
| #638 | counterexample, confirmed | `issue.resolutionInScope` | `w638IdleCommandActsInTurnTest` | `proofs/requests`: `w638IdleCommandActsInTurnTest` | regression test `extensions/behaviors/actions/sessions/tests/idle_command_refuses_when_busy_test.fnl` |
| V1 (#397) | counterexample | `issue.cancelHitsSeenTurn`, `issue.steeringReachesSeenTurn` | `w397CancelHitsSeenTurnTest`, `w397SteeringIntoOtherTurnTest` | `proofs/controls`: `w397CancelHitsSeenTurnTest`, `w397SteeringIntoOtherTurnTest`, `w397StaleSteerStartsTurnTest` | line trace of the reused code (`request-cancel`, `steering.service`) |
| V2 (#398) | counterexample | `issue.noPendingForEndedTurn` | `w398TurnRequestOutlivesTurnTest` | `proofs/requests`: `w398TurnRequestOutlivesTurnTest`, `w398AnswerForEndedTurnTest` | design only (no code yet) |
| V4 (#398) | counterexample | `headless.pendingHasPossibleResolver` | `w398HeadlessRequestNoResolverTest` | `proofs/requests`: `w398HeadlessRequestNoResolverTest` | design only; today's fallback traced in `presenter.fnl` |
| V5 (#398) | counterexample | `issue.noStaleContinuation` | `w398StaleContinuationAfterReloadTest` | `proofs/requests`: same name | design only |
| V6 (#398) | counterexample | `issue.answerMatchesShownChoices` | `w398AnswerAgainstStaleChoicesTest` | `proofs/requests`: same name | design only; `replace-choices!` and `postSelect` traced |
| V7 (#398) | counterexample | `issue.answersAcked` | `w398LateAnswerUnackedTest` | `proofs/requests`: same name | design only, against `docs/wire.md` |
| V8 (#396) | counterexample | `issue.noSilentGap`, `issue.caughtUpSeesTurn`, `issue.caughtUpSeesPending`, `issueDup.noDuplicateDelivery`, `issueDup.inOrderDelivery` | `w396ReplayGapTest`, `w396CaughtUpMissesTurnTest`, `w396CaughtUpMissesPendingTest`, `w396ReplayDuplicatesTest`, `w396ReplayOutOfOrderTest` | `proofs/replay`: `w396ReplayGapTest`, `w396CaughtUpMissesStateTest`, `w396ReplayDuplicatesTest`, `w396ReplayOutOfOrderTest` | design only; `make-flush` traced (the JSONL holds messages only) |
| V9 (#396) | counterexample | `webReuse.answerHitsItsRequest`, `webReuse.remoteNoCommands` | `w396BareIndexHitsOtherRequestTest`, `w396RemoteSlashCommandTest` | `proofs/requests`: `w396BareIndexHitsOtherRequestTest` | line trace of `web/server.fnl` (`finish-select!`, `drain-inputs!`) |

Only #638 is a bug in today's code, so it is the only one with a probe; V1–V9 are findings against designs that have no code to probe.
The `holds` rows of the integration model are sampled evidence; the proposed protocol's guarantees are proved in the proof models.

## Design bugs

Counterexamples are the shortest the simulator found (`quint run --max-steps=N`; the client numbers are filled in from the guards).
The V1 cancel trace and the V8 mid-turn attach were also replayed as scripted `quint test` runs.

### V1. Cancel and steering hit the turn that is running when they arrive, not the turn the sender saw (#397)

Counterexamples:

- `cancelHitsSeenTurn`: `connect(1) → finishReplay → send(0) [turn 1] → turnEnd → send(0) [turn 2] → deliver(1) [remote now sees turn 1] → cancel(1)`. The remote cancel kills turn 2, which the local user started and the remote never saw.
- `steeringReachesSeenTurn`: `connect(1) → finishReplay → send(0) [turn 1] → send(1) → inject`. Remote 1 still sees idle and sends a new prompt. It arrives while turn 1 is busy, so `on-submit` queues it as steering, and it is injected into the local user's turn 1 as a mid-turn correction.
- The same invariant also catches a stale steer that arrives after its turn ended. That steer either starts a fresh turn (`busy?` is false) or waits in the queue for the next turn (the inherited [tui-turns #662](../tui-turns/FINDINGS.md)).

What the design reuses: `interactive.fnl` `request-cancel` is `(when state.busy? (set state.cancel-requested? true))`, which names no turn.
`steering.service` queues bare strings (`(table.insert q text)`), and `submit` decides prompt or steering from `ctx.busy?` at processing time.
#397 says to wire cancel "to the same path the TUI uses" and to inject "into the existing steering/follow-up queues".
That is safe for the TUI, which sees the turn change synchronously.
It is unsafe for any client whose view lags, and a remote view always lags by at least one network round trip.
`turn_submit.start!` already numbers turns (`state.turn-id`), so the id a targeted control needs already exists.
The [wire](../wire/FINDINGS.md) domain's #664 and #665 are the same mistake on the parent/child channel: a control decided on a stale mirror.

### V2. A pending request outlives the turn it was issued from (#398 leaves it open)

Counterexample (`noPendingForEndedTurn`): `send(0) [turn 1] → toolRequest → cancel`.
Answering it afterwards (`resolutionInScope`) gets the answer accepted, with first-writer-wins, for a turn that no longer exists.
#398 says what happens to late answers, but not what happens to the request when its turn is cancelled, errors, or ends.
Clients keep showing the picker, and the "winning resolution" broadcast announces a choice that had no effect.
If the implementation resumes "the parked turn" and not "the turn that issued this id", the answer drives the next turn's question.

### #638: An idle-only command acts after a turn starts under its open picker (existing code; #397 and #398 widen it)

Counterexample (`resolutionInScope`): `cmdRequest(0) [/resume picker] → send [a turn starts] → answer`.
`command.dispatch` checks `:idle-only?` once, before the handler runs.
`pick-session!` then blocks in `ui.select`, and the TUI overlay keeps calling `on-tick` (`pump-background-ticks!`).
`on-tick` runs `steering.start-idle-follow-up!`, which can start a turn.
When the picker returns, `resume-session!` swaps `state.agent` and `state.session` under the running turn.

Confirmed with a Busted probe, now regression test [`idle_command_refuses_when_busy_test.fnl`](../../extensions/behaviors/actions/sessions/tests/idle_command_refuses_when_busy_test.fnl) (fixed in #605).
It drove the real `/resume` handler through `command-registry.dispatch`, with a ui slot whose `select` enqueues a follow-up with `start-if-idle?` and runs `start-idle-follow-up!` the way the overlay's tick does:

```
PROBE during select: busy?	true	turn-id	1
PROBE after /resume: busy?	true	session	/s/other.jsonl	agent replaced?	true
```

Today this needs an extension's `api.enqueue` to land while a picker is open, so it is rare.
Under #397 any remote prompt does the same thing.
Under #398 the window is no longer "while the local user looks at a modal" but "until anyone answers", and #398 deletes the old synchronous path.

### V4. With no in-process presenter, a request can wait forever and wedge the process (#398)

Counterexample (`headless.pendingHasPossibleResolver`): `connect(1) → finishReplay → send(1) [turn 1] → toolRequest → disconnect(1)`.
Today, with no `ui` slot, `ui.select` returns nil at once (`presenter.fnl` `FALLBACKS`: "returning nil rather than block on stdin"), and the `rpc` presenter registers no `:ui`.
Under #398 the turn parks until a client answers, and #394 says remote clients are optional observers.
A parked turn is still busy, so `reload-request.drain!` (which runs only when `(not (or state.busy? state.turn))`) and every `:idle-only?` command are blocked too.
#398 names no timeout, no default answer, and no rule for when no client is attached.

### V5. A command's pending request survives `/reload` and then runs pre-reload code (#398 leaves it open)

Counterexample (`noStaleContinuation`): `cmdRequest → reload → answer`.
`/reload` is idle-only, so it cannot run under a parked turn, but an idle-scoped picker leaves the process idle.
To make a command's picker async, its continuation (the rest of `pick-session!` or `pick-model!`) must be stored until the answer arrives.
That is a function captured in long-lived state.
AGENTS.md's hot-reload invariant forbids exactly that: "Resolve cross-module behavior at call time … instead of capturing function locals in long-lived state."
#398 does not say where pending requests live, or whether they survive a reload.
A pending-request table in a reloadable module would lose them instead: clients would still show the request, and every answer would hit an unknown id.

### V6. A picker whose choices change cannot be expressed as one `select-requested` (#398)

Counterexample (`answerMatchesShownChoices`): `cmdRequest [/model] → updateChoices → answer`.
`pick-model!` passes `:on-tick (discovery-tick …)`, and `select.fnl` calls `replace-choices!` as model discovery finishes.
The choice list changes while the request is pending.
#398's pair carries the choices once.
A remote answer made against the first list, by index (which is what `page.fnl` `postSelect` sends today: `body: String(value)`), selects from the refreshed list on the server.

### V7. Late answers are "ignored", but the wire protocol acks every control (#398 against `docs/wire.md`)

Counterexample (`answersAcked`): `cmdRequest → answer → cmdRequest → answer(request 1 again)`.
#398: "late answers are ignored and the winning resolution broadcast."
`docs/wire.md`: "Every control line gets exactly one `control-ack`".
If a select answer is a control on that wire, the two contracts conflict.
A broadcast does not replace an ack, because the late client may be disconnected or may have picked the same choice as the winner.
Today's web `/select` returns 204 whether or not the answer counted.

### V8. JSONL replay drops or repeats events, and loses the turn state and the pending requests (#396)

Counterexamples:

- `issue.noSilentGap` (replay, then live): `connect(1) → send(0) [turn 1 + user message] → finishReplay → toolRequest → deliver(1)`. The user message appended during the yielding replay is in neither the snapshot nor the live stream, and the client gets later events with no sign of the hole.
- `issueDup.noDuplicateDelivery` (live, then replay): `send(0) → connect(1) → replayStep → turnEnd → deliver(1) → replayStep → replayStep`. The assistant message appended during replay arrives live and again from the growing file. `issueDup.inOrderDelivery` gets the same message out of order.
- `caughtUpSeesTurn` (`connect(1) → send(0) → finishReplay`) and `caughtUpSeesPending` (`connect(1) → cmdRequest → finishReplay`): the client finishes replay caught up, yet believes the agent is idle and knows no pending request. The scripted `midTurnAttach` run (`send(0) → toolRequest → connect(1) → replay ×3 → finishReplay`) shows both after a full replay.

The session JSONL holds messages only (`session_lifecycle.fnl` `make-flush` appends `agent.messages`), so it has no `turn-started`, no `select-requested`, and no queue state.
It also holds no messages at all until the first assistant message exists (`assistant-present?`).
#396 requires yielding replay but does not say how replay and live events are sequenced.
Nothing assigns the client a position it could resume from, so every reconnect is a full replay with neither a "you missed events" signal nor a resume.
Downstream, a client that thinks the agent is idle sends a prompt that becomes steering (V1), and it can never answer the request it cannot see (V4).

### V9. The web handlers #396 says to reuse answer the wrong select and give remote clients slash commands

Counterexamples:

- `webReuse.answerHitsItsRequest`: `cmdRequest → answer(1) → cmdRequest → answer(stale 1)`. The stale answer resolves request 2. `finish-select!` ignores `sel.id` and applies the POST body (a bare index) to `state.active-select`, whatever that is now.
- `webReuse.remoteNoCommands`: `connect(1) → finishReplay → cmdRequest(1)`. A remote line starting with `/` is dispatched as a command: `/input` → `enqueue-input!` → `drain-inputs!` → `ctx.on-submit`, which sends `/…` lines to `command-registry.dispatch`. That gives a remote observer `/resume`, `/new`, `/model`, `/reload`, and `/plan approve`, the one approval plan mode keeps away from the model ("This tool never approves or executes a plan").

#397's queue-only rule avoids the second problem, because queued text is injected as user text and never dispatched.
The problem appears only if serve reuses the web `/input` path as #396 suggests.

### What the issue designs already get right

- `singleTurn`: local and remote input never start two concurrent turns. Everything runs on one cooperative thread, and `turn_submit.submit!` and `on-submit` check `state.busy?` before starting a turn.
- `resolvedAtMostOnce`: with request ids and first-writer-wins (#398), no request is resolved twice.
- `answerHitsItsRequest`, `remoteNoCommands`: these hold under the issue designs as written, with ids and queue-only input; V9 shows they fail only with the reused web code.
- `pendingHasPossibleResolver` holds whenever the TUI is attached, because it can always answer. This is a safety property of each state (someone who *could* resolve the request exists), not a promise that anyone does: with no fairness assumed, "every request is eventually resolved" is a liveness claim the model cannot make. A deadline counts only when it is armed on that request (`Req.deadline`), not because the design has timeouts somewhere (the old `pendingHasAnswerer` accepted the `TIMEOUTS` flag itself, so a request issued without a deadline passed; the last mutant in `mutants.tsv` is that case).

## Required guarantees

The proposed protocol (`proposed`, `proposedTui`) satisfies every invariant.
In words:

1. **One event sequence, owned by the process.** Every bus event serve forwards gets a seq that increases across the whole process, inside an envelope that carries the run (process) id, using the existing `fen.util.wire` envelope. A client attaches with `resume {run, after-seq}`. If the run matches and the seq is still in a bounded in-memory ring, serve replays from `after-seq + 1` and continues live from a per-client cursor. Otherwise it sends an explicit `reset` followed by a snapshot (V8).
2. **The snapshot is complete, and it is taken at a recorded seq.** A snapshot carries the messages (from `agent.messages`, not by re-reading the JSONL), the running turn id or idle, the queue contents, and every pending request with its current choices and version. It is taken at seq S, and live delivery starts at cursor S, so yielding while it is sent cannot drop or repeat events (V8). A client that falls behind the ring is disconnected and gets a reset when it reconnects.
3. **Every control names the turn its sender saw.** `prompt {expect: idle}`, `steer {turn}`, and `cancel {turn}` are applied only if that is still the state. Otherwise they get a rejection ack that carries the current turn id. Steering lines are stored with their turn, and when a turn ends its unconsumed lines are handed back (acked as rejected), never left for the next turn (V1, tui-turns #662).
4. **Every control gets exactly one ack**: accepted, rejected with a reason, or applied. This covers select answers, late and duplicate ones included, as `docs/wire.md` already requires (V7).
5. **A request id is unique within its run, and its scope is recorded when it is issued**: a turn id, or "idle" for a command picker. An answer names the id and the choice version it was made against, and picks a choice by a stable key, not a list index. A refreshed choice list is broadcast as `select-updated` with a new version (V6, V9).
6. **Every request resolves exactly once**, as answered, cancelled, timed out, turn-ended, or reloaded, and the resolution, with its reason and winner, is broadcast. Ending or cancelling a turn resolves that turn's requests. `/reload` resolves the pending idle-scoped requests (V2, V5).
7. **A resolution is applied only in its scope.** A turn-scoped answer resumes only the turn that issued it. An idle-scoped continuation re-checks its precondition (still idle, same session) before it acts, and aborts with a visible error otherwise. Pending continuations are stored as data (request id, command name, arguments) and resolved through module lookup at resume time, not as captured closures (#638, V5).
8. **No request waits forever.** Every request has a deadline and a defined default (nil, the same as Esc in the TUI picker). When no client that can answer is attached, the request resolves at once to that default. That is the same behaviour as today's no-presenter fallback (V4).
9. **Remote authority stays within the session's policy.** Remote lines reach only the steering and follow-up queues and are never dispatched as slash commands. Answers are limited to the choices of a pending request. Anything more (remote slash commands, per-client roles) is a separate decision (V9).

## Proof models

The integration model mixes the three protocols in one state machine, which is right for reproducing bugs but too big for Apalache.
Each protocol has its own proof model under `proofs/`, with only the state its contract needs.
Each is proved for the proposed protocol and keeps the issue designs as counterexample instances (`violated` rows with their own witnesses).

| Proof model | Contract | State | Instances | Obligation | Result |
| --- | --- | --- | --- | --- | --- |
| [`controls`](proofs/controls/model.qnt) | cancel and steer carry the turn the sender saw (guarantee 3; V1) | running turn id, each client's last-seen turn, the steering queue as a set of turn tags | `issue` (#397), `proposed` | `proposed.inductiveInv` inductive; `cancelHitsSeenTurn steeringReachesSeenTurn` bounded, 8 steps | inductive [3 s]; bounded-safe [1 s] |
| [`requests`](proofs/requests/model.qnt) | request scope, exactly-once resolution, turn-end and reload resolution, deadlines, acks, choice versions (guarantees 4–8; #638, V2, V4–V7, V9) | the turn (running, id, parked request), reload generation, any remote connected, a fixed table of 3 request ids | `issue`, `headless`, `webReuse`, `proposed`, `proposedTui` | `proposed.inductiveInv`, `proposedTui.inductiveInv` inductive | inductive [4–14 s], inductive [4–9 s] |
| [`replay`](proofs/replay/model.qnt) | seq cursor, snapshot at a recorded seq, reset after ring overrun (guarantees 1–2; V8) | a log of 6 seqs (persisted? and state after), one remote client's cursor, delivered seqs, and view | `issue` (`jsonlGap`), `issueDup`, `proposed` (`ring`) | `proposed.inductiveInv` inductive | inductive [3–7 s] |

Times are wall clock over two runs (ranges where they differed), with one Apalache lane (`SPEC_VERIFY_JOBS=1`, `JVM_ARGS=-Xmx3g`).
Each `inductiveInv` is the property conjoined with a finite type invariant and the strengthening that makes it one-step preserved; the model headers and the comments above each `inductiveInv` state the strengthening.
"Inductive" here is for the model's fixed constants (3 turns, 3 requests, 6 seqs): induction removes the depth bound, not the bound on ids.
A bounded 8-step obligation on the request model (`proposedTui.allInvariants`) timed out at 600 s, which is why that model is proved by induction only.

Each proof directory has its own `mutants.tsv`, removing one guarantee at a time (turn-end hand-back, targeted cancel, the turn check on steering; turn-end resolution, idle re-check, reload resolution, deadlines, version check; snapshot seq, snapshot state, resume cursor). Every mutant is caught.

## Core

All of these bugs come from one design gap.
The designs carry the current turn, the current request, and the current snapshot implicitly, as "whatever is true when the message arrives".
The wire protocol already avoids this for subagents: it has `seq`, `ref`, a `control-ack` for every control, and a state table.
That is the same root cause as tui-turns ("resolves the current turn through a global at the time of use").

The minimal core is small, and most of it already exists:

- **Wire envelope and acks** (`fen.util.wire`): reuse as is for serve, with `seq` assigned per process and `run` set to the process id. `control-ack` gives guarantee 4 (V7) for free.
- **Event bus**: serve stays an `api.on :*` subscriber plus a bounded ring and a cursor per client, with no new hook or kind. `select-requested`, `select-resolved`, and (for V6) `select-updated` are ordinary bus events, which #398 already proposes.
- **One new piece of core state**: a pending-request table in a non-reloadable state module, keyed by `{id → scope, deadline, choices-version, continuation-ref}`, with one rule: turn end and reload resolve the matching entries. This is the only genuinely new mechanism, and it replaces `wait-select`'s private loop and the TUI overlay's inner event loop.
- **Turn-tagged controls**: `state.turn-id` already exists. Cancel and the steering queue need to carry it and compare against it. That is a change to existing data, not a new queue kind, so it fits #397's "no new queue kinds".

So most of serve can reuse what fen already has: the wire schema, the bus, the steering queue (tagged with the turn), and the wire-session ack discipline.
The core change #398 must carry is the request table with its resolution rules, not only the event pair.

## Open questions

- **Process restart.** Required guarantee 1 assumes the run id changes on restart, so a stale `after-seq` gets a reset and not another run's events. This is not modelled, and the issues do not say what `run` means for serve.
- **Who may answer what.** #394 makes every attached client an equal answerer. If permission prompts become requests, a remote observer with the shared bearer token can approve a tool call. Whether that is intended, or permission requests should be local-only or role-gated, is a policy decision the issues do not make. The model only checks that answers stay within a request's choices.
- **Idle remote prompts.** #397 says inputs go into the steering and follow-up queues, but an idle process has no turn to steer. The model assumes a remote prompt seen-idle starts a turn (as `api.enqueue … {:start-if-idle? true}` does). Whether a remote client may start turns at all is not stated.
- **`ui.prompt` and `has-ui?`.** `/model` branches on `api.ui.has-ui?`. With async requests, "has a UI" becomes "some client may answer", which can change mid-request. The model does not cover it.
- **Subagent escalation.** A child's `select-requested` relayed to the parent's clients adds a second hop. Guarantees 5 to 8 would have to hold end to end (the child's deadline must outlast the parent's). Not modelled.
