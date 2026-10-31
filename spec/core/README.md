# Core primitives

The domain models under `spec/` describe today's code, one subsystem at a time.
Their findings converge on a small core (see "The small core" in [`../README.md`](../README.md)).
This directory models that core: one directory per primitive, each with an abstract specification proved on its own, which the domains then refine.

## How a primitive is used

| File | Purpose |
| --- | --- |
| `abstract.qnt` | The contract as an abstract state and a step relation (`absNext`), pure definitions only, so concrete models can import it. |
| `model.qnt` | The abstract machine: every move an owner of the primitive can make. Its invariants are proved inductively (`verify.tsv`), so they hold at any depth. |
| `<name>.qnt` | Pure helper functions a domain may share (e.g. `turn.qnt`'s replay rule). |
| `witnesses.qnt`, `mutants.tsv` | Reachability of the interesting cases, and broken variants the invariants must catch, so the proof is not vacuous. |

A domain refines a primitive with a **refinement mapping** from its own state to the abstract state, and a **monitor**: a ghost copy of the previous abstract state, and the invariant `absNext(prevAbs, absOf(state))`, which says every concrete step is an abstract step or a stutter.
The mapping reads what the concrete state actually holds (for close-turn, the calls the history leaves open); it must not repair in-flight state first, or it would hide the very bugs the monitor is for.
When the monitor holds, the abstract invariants hold for the domain too; when it fails, the counterexample is a concrete step that no correct owner could take.

Sharing pure functions between domains (as sessions shares `turn.qnt`'s replay rule) is reuse, not refinement: a wrong shared rule would pass everywhere.
That is why the replay rule also has its own laws (`replay/`), checked independently of any domain.

## Primitives

| Primitive | Issue | Status | Refined or used by |
| --- | --- | --- | --- |
| [turn](turn/abstract.qnt): close-turn | #668 | abstract spec proved inductively (~10 s) and to 10 steps | agent-loop: `currentRefines`/`fixedRefines` monitors on the integration model (sampled), and `proofs/loop` (bounded-safe to 12 steps) |
| [replay](replay/model.qnt): replay of a log cut anywhere | #668 | six laws bounded-safe over every log of up to 5 entries (2–13 s each) | sessions (`fixed` replay, provider check, doctor; `proofs/replay` checks the sessions projection against the same laws) |
| [store](store/abstract.qnt): kernel lock plus atomic replace | #669 | abstract spec proved inductively (~5 s) and to 10 steps | sessions (`proofs/lock`, `proofs/persistence`), auth (`proofs/rotation`), tools (`proofs/file-commit`) |
| [job](job/abstract.qnt): process group and output capture | #670 | abstract spec proved inductively (~8 s) and to 10 steps | tools (`proofs/process-group`, `proofs/popen-cancel`, `proofs/output-envelope`), subagents (`proofs/lifecycle`) |
| [tasks](tasks/abstract.qnt): one task table with turn-keyed ownership, async request table, and countdown budgets | #671 | `tasksSpec` proved inductively (~16 s) and to 10 steps; `requestsSpec` proved inductively (~39 s) | scheduler (`proofs/cancel-arm`, `proofs/pump`), tui-turns (`proofs/ctrl-c`, `proofs/side-ownership`), serve (`issueRefines`/`proposedRefines`/`proposedTuiRefines`, `proofs/requests`) |
| [ledger](ledger/abstract.qnt): usage as a fold over one log | #672 | abstract spec proved inductively (~11 s) and to 10 steps | context (`proofs/ledger`), presenters (`proofs/outcome`) |
| [contrib](contrib/abstract.qnt): per-owner extension contribution map | #673 | abstract spec proved inductively (~6 s) and to 10 steps | extensions (`proofs/contrib`, `proofs/turn-identity`), context |
| [runs](runs/abstract.qnt): subagent run table and mailbox | #674 | abstract spec proved inductively (~2 s) and to 10 steps | subagents (`proofs/lifecycle`), wire (`proofs/acks`) |
| [policy](policy/abstract.qnt): child policy derived from the parent | #675 | abstract spec proved inductively (~9 s) and to 10 steps | subagents (`proofs/inheritance`), auth (`proofs/pinning`), extensions (`proofs/validation`) |

## turn

Abstract state: the open calls (in order), whether a turn is open, whether the model is owed a reply, the outcome, whether an `:error` was announced, and the parity of the model's replies (so a reply nobody owed is a visible step, not a stutter).

| Abstract step | Allowed when |
| --- | --- |
| user input | nothing is open |
| reply (with any calls) | the turn is open, the model is owed a reply, nothing is open |
| answer (the next k calls, in order) | calls are open |
| signal error | the turn is open |
| close (pairs everything open, one outcome) | the turn is open; `ok` only if the model's reply is the newest thing in context; `error` only if announced |

Inherited invariants: a closed turn has nothing open, an outcome exists exactly when the turn is closed, an error outcome was announced, and the model is never owed a reply while a call is open.

Today's agent loop fails refinement in five ways, one per bug: a `:length` reply closes the turn with its call open (#606), a crash does too (#607), the model is asked for a reply nobody owed (#608), and a refused (#609) or capped (#610) turn closes `ok` while the model is still owed a reply.
The fixed loop refines the spec.

## replay

Laws, each checked on one log chosen in `init` (one Apalache step, every log of up to 5 entries over call ids {0, 1}, including orphan, duplicate, and reordered results):
`replayValid`, `replayKeepsValid`, `doctorCleanIffValid`, `closeTurnValid`, `closeTurnIdempotent`, `replayEqualsClose` (a log cut at any point replays to what close-turn gives in memory).
`replayIdempotent` follows from `replayValid` and `replayKeepsValid`; it stays a sampled check, because replaying a replay is what makes Apalache time out.

## tasks

`tasks/abstract.qnt` defines two pure abstract contracts for `#671`:
- `tasksAbstract` (`tasksSpec`): cooperative task slots (`t1Status`, `t2Status`), owner turns (`t1Owner`, `t2Owner`), cancel requests and arms (`t1Cancel`, `t1Armed`), active poll cadence (`anyRunnable == pollActive`), and `xpcall` fault isolation (`faultCaught`).
- `requestsAbstract` (`requestsSpec`): whether a turn is open (`running`), its id (`turnNo`), which request it is parked on (`parkedOn`), the `/reload` generation (`gen`), whether any resolver is attached (`hasResolver`), the set of turn tags in the steering queue (`queue`), and the pending-request table (`rScope`, `rGen`, `rVer`, `rStatus`, `rRes`, `rRem`).

| Abstract step (`requestsAbstract`) | Allowed when |
| --- | --- |
| start turn (`absStartTurn`) | idle (`not(running)`) |
| end/cancel turn (`absEndTurn`) | running; resolves every pending request with `rScope == turnNo` to `"ended"` and clears `queue` |
| queue / inject steer (`absQueueSteer`, `absInjectSteer`) | running; queued lines carry `turnNo` |
| open request `i` (`absOpenReq`, `bgt >= 1`) | `scope == turnNo` (running, unparked) or `scope == 0` (idle, no other idle picker open); if `hasResolver`, enters `"pending"` with countdown `rRem = bgt`; otherwise resolves immediately to `"timeout"` (`rRes = 1`, `rRem = 0`) without parking |
| update choices (`absUpdateChoices`) | pending idle picker (`rScope == 0`); increments `rVer` |
| answer request `i` (`absAnswer`) | pending and `hasResolver`; resumes turn if `rScope == turnNo`, applies if `rScope == 0` and idle, or aborts (`"aborted"`) if a turn started underneath (#638) |
| tick / timeout (`absTickOrTimeout`) | pending; either decrements `rRem > 1` or resolves to `"timeout"` (an upper-bound step relation allowing early or deadline timeout) and unparks |
| reload (`absReload`) | idle; increments `gen` and cancels pending idle pickers (`rScope == 0`) |
| set resolver (`absSetResolver`) | remote connects or disconnects; if `not(hasRes)`, pending requests either keep their countdown or resolve immediately to `"timeout"` |

Inherited invariants (`absInv` and `reqAbsInv`): cancel arms and requests are isolated to their owning task (`ownershipIsolated`, `cancelRequiresRegistered`), poll cadence matches runnable work (`cadenceMatchesRunnable`), every request resolves at most once (`resolvedOnce`), no request outlives its turn (`noOrphanTurnReq`), `parkedOn` and pending turn-scoped requests agree (`parkConsistent`), no pending request belongs to a prior reload generation (`pendingCurrentGen`), every queued steering line belongs to the running turn (`queueOwnedByRunningTurn`), and every pending request has a strictly positive remaining tick budget (`pendingBoundedBudget`, `boundedWaitTicksInv`).
