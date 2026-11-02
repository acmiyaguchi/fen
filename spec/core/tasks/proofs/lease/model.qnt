// Proof model, layer L0 of the holder design: the session lease alone.
//
//   L0 lease  (this file)        who holds the session, whether its body runs,
//                                the turn number, cancel fencing, start requests
//   L1 line   (../line)          one representative queued line against the lease
//   L2 holder (../holder)        the full mailbox; refines L0 and, per line, L1
//   L3 code   fen.core.tasks     by trace replay
//
// L0 is small on purpose: liveness is checked here, where the state is a
// handful of booleans and one counter, and carried up by refinement (L2's
// fairness assumptions map onto L0's fair actions; see ../holder).
//
// Liveness, two ways:
//   - temporal: `releaseEventually`, `requestedStartEventually` under weak
//     fairness (quint verify --temporal; TLC only, not run by verify.tsv;
//     the finite mirror ../liveness is checked by `make check-liveness`);
//   - bounded, as safety: the same forced-step encoding L2 uses, so the
//     bound invariants are inductive.

module leaseAbstract {
  pure val LEASE_KINDS = Set("none", "turn", "exclusive")

  type Lease = {
    kind: str,       // "none" | "turn" | "exclusive"
    n: int,          // current (or last) turn number; only turns consume one
    hid: int,        // holder id: every acquire (turn or exclusive) takes a fresh one
    body: bool,      // a with-holder body is running
    cancel: bool,    // cancel! n was accepted for the running turn
    startReq: bool,  // an offer (idle or behind an exclusive job) asked for a turn, and a line waits
    exReq: bool,     // an exclusive job (/reload, compaction) is requested and waits for the scheduler
  }

  pure def leaseInit: Lease =
    { kind: "none", n: 0, hid: 0, body: false, cancel: false, startReq: false, exReq: false }

  // next-start! + (with-holder :turn ...): consumes the request.
  pure def leaseStartTurn(a: Lease): Lease =
    { ...a, kind: "turn", n: a.n + 1, hid: a.hid + 1, body: true, cancel: false, startReq: false }

  // next-job! picks a requested exclusive job (/reload, /handoff, compaction);
  // consumes the request and no turn number.
  pure def leaseStartExclusive(a: Lease): Lease =
    { ...a, kind: "exclusive", hid: a.hid + 1, body: true, cancel: false, exReq: false }

  // An exclusive job is requested; only the scheduler starts it.
  pure def leaseRequestExclusive(a: Lease): Lease = { ...a, exReq: true }

  // The body exits (return, error, or after a cancel): leaseRelease.
  pure def leaseRelease(a: Lease): Lease = { ...a, kind: "none", body: false, cancel: false }

  // cancel! h: fenced on the holder id, for turns and exclusive jobs alike.
  pure def leaseCancel(a: Lease, h: int): Lease =
    if (a.kind != "none" and h == a.hid) { ...a, cancel: true } else a

  // A start request appears (an idle offer) or goes away (its line was
  // cleared or taken by a turn).
  pure def leaseSetStartReq(a: Lease, r: bool): Lease = { ...a, startReq: r }

  pure def leaseNext(a: Lease, b: Lease): bool = or {
    a == b,
    a.kind == "none" and a.startReq and b == leaseStartTurn(a),
    // one scheduler: a requested exclusive job starts only when no turn start is pending
    a.kind == "none" and a.exReq and not(a.startReq) and b == leaseStartExclusive(a),
    b == leaseRequestExclusive(a),
    a.body and b == leaseRelease(a),
    // cancel: only the current holder can be armed
    a.kind != "none" and b == { ...a, cancel: true },
    // start requests: raised while no turn holds (an idle offer, or one behind
    // an exclusive job), dropped anytime
    b == leaseSetStartReq(a, false),
    a.kind != "turn" and b == leaseSetStartReq(a, true),
  }

  pure def leaseInv(a: Lease): bool = and {
    LEASE_KINDS.contains(a.kind),
    (a.kind != "none") == a.body,
    a.cancel implies a.kind != "none",
    a.kind == "turn" implies a.n >= 1,
  }
}

module leaseSpec {
  import leaseAbstract.* from "./model"

  pure val MAX_N = 3
  pure val NS = 0.to(MAX_N)
  pure val MAX_H = 4
  pure val HS = 0.to(MAX_H)
  // Fairness bounds for the safety encoding of liveness.
  pure val MAX_BODY = 4
  pure val MAX_IDLE = 2

  var kind: str
  var n: int
  var hid: int
  var body: bool
  var cancel: bool
  var startReq: bool
  var exReq: bool

  // ---- ghosts ----
  var heldFor: int
  var waitedFor: int
  var cancelOk: bool
  var stepOk: bool
  var starved: bool   // the idle tick was due but could not start the requested turn

  def l: Lease = { kind: kind, n: n, hid: hid, body: body, cancel: cancel, startReq: startReq, exReq: exReq }

  pure def waiting(a: Lease): bool =
    a.kind == "none" and a.startReq and a.n < MAX_N and a.hid < MAX_H

  action init = all {
    kind' = "none", n' = 0, hid' = 0, body' = false, cancel' = false, startReq' = false, exReq' = false,
    heldFor' = 0, waitedFor' = 0, cancelOk' = true, stepOk' = true, starved' = false,
  }

  // Boolean right-hand sides are parenthesized on purpose (quint reads a bare
  // `x' = a or b` in an action as an action-level `or`).
  action go(b: Lease, gCancel: bool): bool = goS(b, gCancel, false)

  action goS(b: Lease, gCancel: bool, gStarved: bool): bool = all {
    starved' = (starved or gStarved),
    kind' = b.kind, n' = b.n, hid' = b.hid, body' = b.body, cancel' = b.cancel, startReq' = b.startReq, exReq' = b.exReq,
    heldFor' = if (b.kind == "none" or kind == "none") 0 else heldFor + 1,
    waitedFor' = if (waiting(b) and waiting(l)) waitedFor + 1 else 0,
    cancelOk' = (cancelOk and gCancel),
    stepOk' = (stepOk and leaseNext(l, b)),
  }

  // The implementation's start guard, kept apart from `waiting` (the spec).
  pure def canStart(a: Lease): bool = a.startReq and a.kind == "none"

  // The whole start guard in one place; the deadline tick is total over it
  // (doStartTurn when it holds, doStarved otherwise), so a guard bug is
  // recorded as `starved` rather than deadlocking the forced step.
  pure def startGuard(a: Lease): bool = canStart(a) and a.n < MAX_N and a.hid < MAX_H
  action doStartTurn: bool = all { startGuard(l), go(leaseStartTurn(l), true) }
  action doRequestExclusive: bool = all { not(exReq), go(leaseRequestExclusive(l), true) }
  action doStartExclusive: bool = all { kind == "none", exReq, not(startReq), hid < MAX_H, go(leaseStartExclusive(l), true) }
  // Total at the body deadline: its only guard is `body`, the deadline condition.
  action doBodyExit: bool = all { body, go(leaseRelease(l), true) }

  action doCancel(m: int): bool =
    val b = leaseCancel(l, m)
    go(b, (not(b.cancel and not(cancel)) or m == hid))

  action doStarved: bool = all {
    not(startGuard(l)),
    goS(l, true, true),
  }

  action doRequestStart: bool = all { kind != "turn", not(startReq), go(leaseSetStartReq(l, true), true) }
  action doDropStart: bool = all { startReq, go(leaseSetStartReq(l, false), true) }

  action step = {
    nondet m = HS.oneOf()
    if (body and heldFor >= MAX_BODY) doBodyExit
    else if (waiting(l) and waitedFor >= MAX_IDLE) (if (startGuard(l)) doStartTurn else doStarved)
    else any {
      doStartTurn,
      doRequestExclusive,
      doStartExclusive,
      doBodyExit,
      doCancel(m),
      doRequestStart,
      doDropStart,
    }
  }

  // The same machine without the forced moves, for the temporal properties
  // under explicit weak fairness.
  action stepFree = {
    nondet m = HS.oneOf()
    any {
      doStartTurn,
      doRequestExclusive,
      doStartExclusive,
      doBodyExit,
      doCancel(m),
      doRequestStart,
      doDropStart,
    }
  }

  // ---- Properties ----

  val movesAreAbsSteps = stepOk
  val leaseInvHolds = leaseInv(l)
  val cancelFencedInv = cancelOk
  val releasedInTimeInv = heldFor <= MAX_BODY
  val startedInTimeInv = waitedFor <= MAX_IDLE and not(starved)

  val allInvariants = and {
    movesAreAbsSteps,
    leaseInvHolds,
    cancelFencedInv,
    releasedInTimeInv,
    startedInTimeInv,
  }

  val inductiveInv = and {
    kind.in(LEASE_KINDS),
    n.in(NS),
    hid.in(HS),
    n <= hid,
    body.in(Bool),
    cancel.in(Bool),
    startReq.in(Bool),
    exReq.in(Bool),
    heldFor.in(0.to(MAX_BODY)),
    waitedFor.in(0.to(MAX_IDLE)),
    cancelOk.in(Bool),
    stepOk.in(Bool),
    starved.in(Bool),
    kind == "none" implies heldFor == 0,
    not(waiting(l)) implies waitedFor == 0,
    allInvariants,
  }

  // ---- Temporal liveness (unbounded, under weak fairness) ----
  val vars = (kind, n, hid, body, cancel, startReq, exReq, heldFor, waitedFor, cancelOk, stepOk, starved)

  // Every with-holder body exits eventually, so the holder is released.
  temporal releaseEventually =
    weakFair(doBodyExit, vars) implies always(kind != "none" implies eventually(kind == "none"))

  // A requested start (while turn numbers remain) eventually starts a turn
  // or is withdrawn.
  temporal requestedStartEventually =
    (weakFair(doBodyExit, vars) and weakFair(doStartTurn, vars))
      implies always(waiting(l) implies eventually(kind == "turn" or not(startReq)))
}
