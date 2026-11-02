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
| [tasks](tasks/abstract.qnt): one task table with turn-keyed ownership, async request table, and countdown budgets | #671 | `tasksSpec` proved inductively (~16 s) and to 10 steps; `requestsSpec` proved inductively (~70 s), including the turn mailbox (`steeringConservedInv`, `followUpsConservedInv`, `followUpOrderInv`, `queueLenConsistentInv`); the implemented mailbox is `proofs/holder`, and `conform.sh` replays `holderSpec` traces through `fen.core.tasks.step` | scheduler (`proofs/cancel-arm`, `proofs/pump`), tui-turns (`proofs/ctrl-c`, `proofs/side-ownership`), serve (`issueRefines`/`proposedRefines`/`proposedTuiRefines`, `proofs/requests`) |
| [ledger](ledger/abstract.qnt): usage as a fold over one log | #672 | abstract spec proved inductively (~11 s) and to 10 steps | context (`proofs/ledger`), presenters (`proofs/outcome`) |
| [contrib](contrib/abstract.qnt): per-owner extension contribution map | #673 | abstract spec proved inductively (~6 s) and to 10 steps | extensions (`proofs/contrib`, `proofs/turn-identity`), context |
| [runs](runs/abstract.qnt): subagent run table and mailbox | #674 | abstract spec proved inductively (~2 s) and to 10 steps | subagents (`proofs/lifecycle`), wire (`proofs/acks`) |
| [policy](policy/abstract.qnt): child policy derived from the parent | #675 | abstract spec proved inductively (~9 s) and to 10 steps | subagents (`proofs/inheritance`), auth (`proofs/pinning`), extensions (`proofs/validation`) |
| [reload](reload/model.qnt): /reload phases atomic under cancel and failure | — | `fixed` proved inductively (~5 s) and to 14 steps; `before` (cancel at `:after-core`/`:after-extensions`, cancel after `recover!`) is witnessed violating `cancelLeavesOld`/`registriesNotLost`/`mixTracked` | uses tasks (`proofs/holder`, holder release) and contrib (per-owner rollback); code: `sessions/commands/session.fnl` `CANCEL-POINTS` |

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
- `requestsAbstract` (`requestsSpec`): the session holder of `proofs/holder` (`ses`, a `holderAbstract::Session`: holder `kind` none | turn | exclusive, turn number `n`, holder id `hid`, the steer and follow-up queues, start and exclusive requests, cancel, drain modes, and every line's disposition `why`/`whyN`), which request the running turn is parked on (`parkedOn`), the `/reload` generation (`gen`), whether any resolver is attached (`hasResolver`), and the pending-request table (`rScope`, `rGen`, `rVer`, `rStatus`, `rRes`, `rRem`). Every session move is one of `holderAbstract`'s pure steps, or a composition of them; nothing of the mailbox is restated here.

| Abstract step (`requestsAbstract`) | Allowed when |
| --- | --- |
| start turn (`sesStartTurn`) | `canStartTurn`: idle with a requested start; `startTurn` (turn `n+1`, fresh `hid`, the asked-for line `started`) |
| prompt turn (`sesPromptTurn`) | idle, no start pending; `startTurn(offer(q, :turn 0))` in one step, for models that fuse the offer and the idle tick. `q` is a fresh seq, or `UNTRACKED_LINE` (outside `SEQS`, so no disposition is recorded) for a model with no mailbox (`serve/proofs/requests`) |
| end/cancel turn (`absEndTurn`) | a turn holds; `release` (unread steer lines `released` to that turn) and every pending request with `rScope == n` resolves `"ended"`, in one step |
| offer (`sesOffer`) | a fresh seq; `offer` with `:turn` -1, 0, `n`, or another turn, follow-up or not |
| take steer / follow-up (`sesTakeSteer`, `sesTakeFollowUp`) | a turn holds and is not parked; follow-ups only once the turn's steer lines are drained |
| cancel, set mode, clear (`cancelHolder`, `setMode`, `clearSteer`, `clearFollowUp`) | any time |
| exclusive job (`requestExclusive`, `sesStartExclusive`, `sesEndExclusive`) | request any time; start when idle, requested, and no turn start pending (turns first); release when the job's body exits |
| reload (`absReload`) | inside an exclusive job (`kind == "exclusive"`); increments `gen` and cancels pending idle pickers (`rScope == 0`) |
| whole reload job (`absReloadJob`) | `startExclusive`; reload; `release`, in one step, for models that do not split the holder (serve) |
| open request `i` (`absOpenReq`, `bgt >= 1`) | `scope == n` (a turn holds, unparked) or `scope == 0` (no turn holds, no other idle picker open); if `hasResolver`, enters `"pending"` with countdown `rRem = bgt`; otherwise resolves immediately to `"timeout"` (`rRes = 1`, `rRem = 0`) without parking |
| update choices (`absUpdateChoices`) | pending idle picker (`rScope == 0`); increments `rVer` |
| answer request `i` (`absAnswer`) | pending and `hasResolver`; resumes the turn if `rScope == n`, applies if `rScope == 0` and no turn holds, or aborts (`"aborted"`) if a turn started underneath (#638) |
| tick / timeout (`absTickOrTimeout`) | pending; either decrements `rRem > 1` or resolves to `"timeout"` (an upper-bound step relation allowing early or deadline timeout) and unparks |
| set resolver (`absSetResolver`) | remote connects or disconnects; if `not(hasRes)`, pending requests either keep their countdown or resolve immediately to `"timeout"` |

**`/reload` is an exclusive job**, as in the code: `/reload` and an agent's reload request go through `tasks.run-exclusive!`/`request-job!` (`extensions/behaviors/actions/sessions/commands/session.fnl` `start-reload!`, `fen.core.reload_request`), so it runs only when no turn holds and after any pending turn start. Its effect (`absReload`) happens inside the job, so a turn-scoped request can never straddle it; only idle pickers can, and they are cancelled.

Inherited invariants (`absInv` and `reqAbsInv`): cancel arms and requests are isolated to their owning task (`ownershipIsolated`, `cancelRequiresRegistered`), poll cadence matches runnable work (`cadenceMatchesRunnable`), the holder's own invariant (`sessionInv`: steer lines only while a turn holds, queued lines undisposed, ...), every request resolves at most once (`resolvedOnce`), no request outlives its turn (`noOrphanTurnReq`), `parkedOn` and pending turn-scoped requests agree (`parkConsistent`), no pending request belongs to a prior reload generation (`pendingCurrentGen`), and every pending request has a strictly positive remaining tick budget (`pendingBoundedBudget`, `boundedWaitTicksInv`). `requestsSpec` also checks the composed mailbox: no line lost (`eachSeqOnceInv`), steering before follow-ups (`followUpOrderInv`), and no refused input behind `/reload` (`localOfferNeverRefusedInv`).

### proofs/holder

`tasks/proofs/holder/model.qnt` models the session **holder** and its mailbox in the vocabulary of the `fen.core.tasks` API, revised after design review (gpt-6.1-sol, Fable); the code implements it.
Code-facing differences: drain modes are spelled `:one-at-a-time`/`:all`; queue kinds in `take!`/`clear!` are `:steering`/`:follow-up`. `with-holder` is realized by the scheduler: `next-job!` is `startTurn` or `startExclusive` (turns first), `request-job!` is `requestExclusive` (plus an immediate `next-job` when idle with no start pending), and `offer-start!` is an offer followed by `startTurn` in one dispatch; `exReq` is "the job queue is non-empty" (the code queues several jobs, coalesced by key). The holder is a tagged union (no `n` on an exclusive holder); every `hid` is registered with its coroutine in the job table, and bodies run under `xpcall`. `cancel!`/`cancel-requested?` take the hid (`cancelHolder`), with `cancel-current!` for Ctrl-C; a pre-holder closure's `state.cancel-requested?` is mapped onto `cancel!` of the polling holder. Lines may carry an opaque body (`:line-turn`) beside the tag. Deprecated `idle-tick!`/`queue!`/`steer-or-follow-up!`/`turn-start!`/`turn-end!` shims (pre-holder runtimes after `/reload`) never take a holder.

| Term | Meaning |
| --- | --- |
| holder | who has the session: nobody, `{kind: turn, n}`, or `{kind: exclusive}` (`/reload`, `/handoff`) |
| n | the current (or last) turn's number; only turns consume one, so wire `turn` numbers stay consecutive |
| steer / follow-up | a line for the running turn / for a natural stop or a later turn |
| seq | the mailbox's own admission number: FIFO order and identity |
| tag | the caller's opaque id (a wire `seq`): carried through, never used for order or lookup, may repeat |
| offer / take | queue input (never starts a turn) / the agent drains lines at a boundary |
| returned | a line leaving unread, with its reason (`started`, `released`, `refused`, `cleared`) and the turn it was for |

API: `(spawn-holder kind f)` is the only way to hold the session; every acquire takes a fresh holder id `hid`; it releases on every exit (return, error, cancel) under `xpcall`, so a holder can never leak and is never replaced.
`(next-start!)` is the single start path: the driver's idle tick takes the head follow-up an idle offer asked for and runs `(with-holder :turn ...)` with it.
`(offer! text {:tag :turn :follow-up?})` routes: no `:turn` steers the running turn, waits behind an exclusive holder, or asks for a start when idle; `:turn 0` means start only if idle; `:turn t` steers only turn `t`.
`(cancel! hid)` is fenced on the holder id, for turns and exclusive jobs alike: Ctrl-C reads the holder id at the keypress, so a late press cannot cancel the next holder.
Dispositions (`why`, `whyN` per seq) are part of the abstract `Session`, so a refinement (serve) must preserve exactly-once, correctly attributed returns.

| Invariant | Meaning |
| --- | --- |
| `holderHasBodyInv` | a holder exists exactly while its body runs: no crash or cancel path can wedge the session |
| `eachSeqOnceInv` | every admitted line is queued or has exactly one disposition (keyed by seq, not tag or text) |
| `steerForHolderInv` | queued steer lines belong to the turn they were offered for; taken and returned ones are attributed to it |
| `startedOpensItsTurnInv` | a started line opened a real turn number |
| `localOfferNeverRefusedInv` | an offer without `:turn` is never refused (it waits behind an exclusive holder) |
| `followUpOrderInv` | follow-ups are taken only after the turn's steer lines |
| `cancelFencedInv` | a cancel never arms a holder other than its target (turn or exclusive) |

**Drain modes.** `set-mode!` sets `:one` or `:all` per queue; `take!` drains exactly what the mode says (`takeByModeInv`), and modes persist across turns, releases, and clears until changed (`modesPersistInv`).

**Liveness, bounded and encoded as safety.** Unbounded temporal checking needs TLC (Apalache does not handle fairness); `quint verify --backend tlc` works (`yes | nix shell nixpkgs#tlaplus nixpkgs#jdk --command quint verify --backend tlc ...`) and catches a leaked holder in about a minute, but only on a model with bounded counters and few nondets: the full holder model is too large. So the fairness assumptions are explicit in the step relation: every `with-holder` body exits within `MAX_BODY` steps, and the driver's idle tick runs at least every `MAX_IDLE` steps. The forced steps are total: the deadline tick is `if (startGuard) doStartTurn else doStarved`, with every start condition in `startGuard`, so a guard bug is recorded as starvation instead of deadlocking the forced step. A pending turn start has priority over an exclusive holder (otherwise alternating exclusive holds starve it forever under weak fairness, and the bounded check, which resets on each hold, would miss it). `releasedInTimeInv` and `startedInTimeInv` are then ordinary inductive invariants. Release is stated on the holder `kind`, not on `body`: a crashed exit can clear `body` and still leak the holder.

**Liveness, temporal, under TLC (`make check-liveness`).** `proofs/liveness/model.qnt` mirrors the L0 lease step relation with `n` and `hid` dropped (they feed only cancel fencing and turn numbering, safety properties proved on `proofs/lease`; no start or release guard reads them), so the state space is finite (about 20 states) and TLC explores it exhaustively. There are no forced steps: fairness is a temporal hypothesis in each property, and a ghost `last` (the last action taken) states "withdrawn" and "finitely many offers". `scripts/spec/liveness.sh` checks each row of `temporal.tsv` and each mutant in `temporal-mutants.tsv` (never starting an exclusive job, consuming a start request without a turn, leaking the holder on exit; each must be violated) in about 25 seconds. It is not part of `make check` or `check-spec` (it needs TLC and a JDK via nix).

| Property | Fairness assumed | Result |
| --- | --- | --- |
| `turnStartLive`: a requested start leads to a turn or a withdrawal | WF(body exit), WF(start turn), WF(start exclusive) | holds |
| `releaseLive`: every holder is released | WF(body exit) | holds |
| `exclusiveLiveWeak`: a requested exclusive job eventually runs | the same WF | **violated**: offer and withdraw forever, or offer, turn, release, offer, ... (`exclusiveLiveWeakNoDrop`) |
| `exclusiveLiveFiniteOffers` | WF + finitely many new offers | holds |
| `exclusiveLiveStrong` | WF + SF(start exclusive) | holds |

So exclusive jobs can be starved by turns, as designed (a pending turn start beats a requested exclusive job): the exclusive start is enabled only between a release and the next offer, which weak fairness does not cover. The job runs if new offers stop eventually, or if the scheduler is strongly fair to it (every release leaves a moment with no pending start, so it is enabled infinitely often).

**One scheduler.** Exclusive jobs (`/reload`, `/handoff`, compaction) do not acquire on their own: they raise an exclusive request (`exReq`) and the scheduler (`next-job!`) starts them only when no turn start is pending, so every holder (turn or exclusive) is started from one place. A plain local offer behind an exclusive job raises the start request, so it starts when the job ends (`behindExclusiveStartsInv`); an explicit follow-up (`>`) still waits for a natural stop. Failures while starting a holder's body are body exits, so they release like any other.

**Refinement layers.**

| layer | dir | what | proof |
|---|---|---|---|
| L0 lease | `proofs/lease` | holder kind, turn number, holder id, body, cancel fenced on the holder id, start request | inductive, ~3 s |
| L1 line | `proofs/line` | one representative line against the lease; other lines abstracted to steerAhead / otherSteer / followAhead | inductive over the generator (~80 s) and over every step `lineNext` allows (`lineSpec@stepRel`, ~20 s) |
| L2 holder | `proofs/holder` | the full mailbox | `inductiveInv` (~25 s); refines L0 (`refinesLeaseInv`, ~25 s) and L1 for every seq (`refinesInv`, ~40 s) |
| L3 code | `fen.core.tasks` | the pure `step` | trace replay of `holderSpec` (`conform.sh`: state, dispositions, forbidden-transition probes) |

`proofs/fence` carries the L0 cancel fence to the holders outside the session lease (side chat turns, headless states, the turn owning a blocking subagent run): per-owner id spaces, a cancel carrying (owner, id) captured earlier, and two invariants, `cancelFencedInv` (never arms a later or another owner's holder) and `cancelNotLostInv` (a cancel for the current holder stays armed until release); inductive, ~3 s. Its mutants are the flag designs it replaced: a per-run flag reset at start, a sticky run-state flag, a reset at body start, and an id without its owner. Code: `fen.util.cancel_fence`.

Refinement is a state predicate over a copy of the previous state (`p*` variables), not a ghost updated in the step: putting `lineNext` in the step relation made every holder proof time out. The L1 proof covers the whole `lineNext` relation, so invariants L2 inherits through `refinesLine` hold for every step the monitor accepts. `verify.sh` takes `main@action` to pick the step action.

Quint 0.32 flattener notes: qualified imports (`import M as X`) lose imported helpers, and selective imports flatten helpers unqualified, so the L0/L1 helpers have unique names (`leaseStartTurn`, `lineDone`, ...) and L2 imports single names.

Fifteen holder mutants are each caught (leaked holder on crash, as a wedge and as a liveness violation; starvation of a requested start; an extra start condition, recorded as starvation; unfenced offer and cancel; refused offer behind an exclusive holder; dropped, misattributed, or leaked returns; follow-up ahead of steering; unreported start or refusal; take ignoring the mode; release resetting the mode). They are caught by simulation; the take-by-mode mutant needs a long trace and is caught reliably only at `SPEC_SAMPLES=50000`.

`holderAbstract` is the session half of `requestsAbstract` (see above): serve's models refine it, composing request cleanup with `release` (`absEndTurn`) and `/reload` with an exclusive job (`absReloadJob`).
