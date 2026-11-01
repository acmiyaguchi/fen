// Proof model (proposed design): the session holder and its mailbox, in the
// vocabulary of the target `fen.core.tasks` API (#662, #671, #681):
//
//   holder     who has the session: none | {kind: turn, n} | {kind: exclusive}
//   n          the current (or last) turn's number; only turns consume one
//              (wire/serve spell it `turn`)
//   steer      a line for the running turn
//   follow-up  a line for a natural stop or a later turn
//   seq        the mailbox's own admission number (FIFO order, identity)
//   tag        the caller's opaque id for a line (a wire seq): carried, never
//              used for order or lookup, and may repeat across callers
//   offer      queue input; never starts a turn
//   take       the agent drains lines at a boundary
//   returned   lines leaving unread, each with a reason and the turn it was for
//
// API: (with-holder kind f), (holder), (offer! text {:tag :turn :follow-up?}),
// (take! kind), (next-start!), (cancel! n), (clear! kind), (set-mode! ...).
//
// `with-holder` is the only way to hold the session: it acquires, runs the
// body, and releases on every exit (return, error, cancel) under xpcall. So
// nothing can leak a holder and nothing ever replaces one. Starting a turn is
// one path: the driver calls `next-start!` at its idle tick and, if it gets a
// line, runs `(with-holder :turn ...)` with it.
//
// Queues are sets of seqs: seqs are issued in increasing order, so FIFO is
// "take the smallest". The select/request half of `requestsAbstract`
// (spec/core/tasks) composes with this lifecycle when serve re-proves against
// it; it is not repeated here.

module holderAbstract {
  pure val KINDS = Set("none", "turn", "exclusive")
  pure val MAX_SEQ = 4
  pure val SEQS = 0.to(MAX_SEQ - 1)
  // Dispositions: "" (not yet), taken, started, released, refused, cleared.
  pure val WHYS = Set("", "taken", "started", "released", "refused", "cleared")
  // Drain modes (set-mode!): take one line per boundary, or all of them.
  pure val MODES = Set("one", "all")

  type Session = {
    kind: str,             // holder kind
    n: int,                // current (or last) turn number
    hid: int,              // holder id: every acquire takes a fresh one; cancel! is fenced on it
    steer: Set[int],       // seqs of steer lines for the running turn
    followUp: Set[int],    // seqs of follow-ups
    start: bool,           // an idle offer asked next-start! to start a turn
    firstUp: int,
    exReq: bool,           // an exclusive job (/reload, /handoff, compaction) waits for next-job!             // the seq that idle offer admitted: it starts first (-1: none)
    cancel: bool,          // cancel! n was accepted for the running turn
    steerMode: str,        // drain mode for take! :steer ("one" | "all")
    followMode: str,       // drain mode for take! :follow-up
    why: int -> str,       // seq -> disposition ("" while queued or unissued)
    whyN: int -> int,      // seq -> turn number at its disposition
  }

  pure def sessionInit: Session = {
    kind: "none", n: 0, hid: 0, steer: Set(), followUp: Set(), start: false, firstUp: -1, exReq: false, cancel: false,
    steerMode: "one", followMode: "one",
    why: SEQS.mapBy(_s => ""), whyN: SEQS.mapBy(_s => 0),
  }

  pure def busy(a: Session): bool = a.kind != "none"

  // Smallest element; only called on non-empty sets of seqs.
  pure def minOf(s: Set[int]): int = s.fold(MAX_SEQ, (acc, x) => if (x < acc) x else acc)

  // Record one disposition reason for a set of seqs, attributed to turn n.
  pure def dispose(a: Session, seqs: Set[int], w: str, at: int): Session = {
    ...a,
    why: SEQS.mapBy(s => if (seqs.contains(s)) w else a.why.get(s)),
    whyN: SEQS.mapBy(s => if (seqs.contains(s)) at else a.whyN.get(s)),
  }

  // ---- steps (pure; the concrete model and serve both call these) ----

  // next-start! + (with-holder :turn ...), one step: the line whose idle
  // offer asked for the start (what the user just typed) opens turn n+1,
  // ahead of older follow-ups left by an earlier turn.
  pure def startTurn(a: Session): Session =
    val first = if (a.firstUp >= 0) a.firstUp else minOf(a.followUp)
    dispose({ ...a, kind: "turn", n: a.n + 1, hid: a.hid + 1, followUp: a.followUp.exclude(Set(first)),
              start: false, firstUp: -1, cancel: false }, Set(first), "started", a.n + 1)

  pure def canStartTurn(a: Session): bool =
    a.start and a.followUp != Set() and a.kind == "none"

  // (with-holder :exclusive f): /reload, /handoff. Consumes no turn number.
  // next-job!: a requested exclusive job, only when no turn start is pending.
  pure def startExclusive(a: Session): Session =
    { ...a, kind: "exclusive", hid: a.hid + 1, cancel: false, exReq: false }

  // request-job!: an exclusive job asks the scheduler; it never starts itself.
  pure def requestExclusive(a: Session): Session = { ...a, exReq: true }

  // The body exits (return, error, or cancel): release, and return the turn's
  // unread steer lines attributed to that turn.
  pure def release(a: Session): Session =
    dispose({ ...a, kind: "none", steer: Set(), cancel: false }, a.steer, "released", a.n)

  // offer! routing. t = -1: local (no :turn); t = 0: start only if idle;
  // t > 0: steer only turn t. Returns the new state for admitted seq s.
  pure def offer(a: Session, s: int, t: int, followUpFlag: bool): Session =
    if (followUpFlag)
      { ...a, followUp: a.followUp.union(Set(s)) }
    else if (t > 0)
      if (a.kind == "turn" and t == a.n) { ...a, steer: a.steer.union(Set(s)) }
      else dispose(a, Set(s), "refused", a.n)
    else if (t == 0)
      if (a.kind == "none") { ...a, followUp: a.followUp.union(Set(s)), start: true,
                              firstUp: if (a.firstUp >= 0) a.firstUp else s }
      else dispose(a, Set(s), "refused", a.n)
    else if (a.kind == "turn") { ...a, steer: a.steer.union(Set(s)) }
    // behind an exclusive job: queue it and ask for a turn once the job ends
    else if (a.kind == "exclusive") { ...a, followUp: a.followUp.union(Set(s)), start: true,
                                      firstUp: if (a.firstUp >= 0) a.firstUp else s }
    else { ...a, followUp: a.followUp.union(Set(s)), start: true,
           firstUp: if (a.firstUp >= 0) a.firstUp else s }

  // take! :steer drains by the session's steer mode.
  pure def takeSteer(a: Session): Session =
    val taken = if (a.steerMode == "all") a.steer else Set(minOf(a.steer))
    dispose({ ...a, steer: a.steer.exclude(taken) }, taken, "taken", a.n)

  // Steering wins: follow-ups only once the turn's steer lines are drained.
  pure def takeFollowUp(a: Session): Session =
    val taken = if (a.followMode == "all") a.followUp else Set(minOf(a.followUp))
    dispose({ ...a, followUp: a.followUp.exclude(taken) }, taken, "taken", a.n)

  // cancel! m: only the running turn m.
  // cancel! h: only the current holder h, turn or exclusive (Ctrl-C reads
  // the holder id at the keypress, so a late press cannot hit the next one).
  pure def cancelHolder(a: Session, h: int): Session =
    if (a.kind != "none" and h == a.hid) { ...a, cancel: true } else a

  // set-mode! kind mode: persists across turns, releases, and clears.
  pure def setMode(a: Session, which: str, mode: str): Session =
    if (which == "steer") { ...a, steerMode: mode } else { ...a, followMode: mode }

  pure def clearSteer(a: Session): Session =
    dispose({ ...a, steer: Set() }, a.steer, "cleared", a.n)

  pure def clearFollowUp(a: Session): Session =
    dispose({ ...a, followUp: Set(), start: false, firstUp: -1 }, a.followUp, "cleared", a.n)

  // Steer lines exist only while a turn holds the session.
  pure def steerOnlyForTurn(a: Session): bool =
    a.steer != Set() implies a.kind == "turn"

  pure def sessionInv(a: Session): bool = and {
    KINDS.contains(a.kind),
    a.n >= 0,
    a.kind == "turn" implies a.n >= 1,
    a.cancel implies a.kind != "none",
    MODES.contains(a.steerMode),
    MODES.contains(a.followMode),
    steerOnlyForTurn(a),
    a.steer.intersect(a.followUp) == Set(),
    // A queued seq has no disposition yet.
    a.steer.union(a.followUp).forall(s => a.why.get(s) == ""),
  }
}

module holderSpec {
  import holderAbstract.* from "./model"
  // Selective imports, and L0/L1 helpers with unique names: quint 0.32 flattens
  // imported helpers into this module, and qualified imports lose them.
  import leaseAbstract.leaseNext from "../lease/model"
  import lineAbstract.lineNext from "../line/model"

  pure val MAX_N = 3
  pure val NS = 0.to(MAX_N)
  pure val MAX_H = 4
  pure val HS = 0.to(MAX_H)
  // Caller tags are arbitrary and may repeat: 0 = absent, 1 and 2 collide.
  pure val TAGVALS = 0.to(2)
  // Bounded liveness, encoded as safety. Fairness assumptions, made explicit:
  // every with-holder body exits within MAX_BODY steps (the agent's work
  // terminates), and the driver's idle tick runs at least every MAX_IDLE
  // steps. The step relation forces those moves when a bound is reached; the
  // invariants then say no holder and no requested start waits longer.
  pure val MAX_BODY = 4
  pure val MAX_IDLE = 2

  // The Session record, split into variables so Apalache can bound each one.
  var kind: str
  var n: int
  var hid: int
  var steer: Set[int]
  var followUp: Set[int]
  var start: bool
  var cancel: bool
  var why: int -> str
  var whyN: int -> int
  var steerMode: str
  var followMode: str
  var firstUp: int
  var exReq: bool

  def s: Session = {
    kind: kind, n: n, hid: hid, steer: steer, followUp: followUp, start: start, firstUp: firstUp, exReq: exReq,
    cancel: cancel, why: why, whyN: whyN, steerMode: steerMode, followMode: followMode,
  }
  var body: bool               // a with-holder body is running
  var nextSeq: int

  // ---- ghosts ----
  var tagOf: int -> int        // seq -> caller tag (carried, never used)
  var forTurn: int -> int      // seq -> turn a steer line was offered for
  var isSteer: int -> bool     // seq -> admitted as a steer line
  var isLocal: int -> bool     // seq -> offered without :turn (Enter, an extension)
  var orderOk: bool            // no follow-up taken while steer lines waited
  var cancelOk: bool           // cancel! never armed a turn other than its target
  var leakFree: bool           // no holder outlived its body
  var heldFor: int             // steps the current holder has held the session
  var waitedFor: int           // steps a requested idle start has waited
  var starved: bool            // the idle tick ran but could not start a requested turn
  var takeOk: bool             // every take! drained exactly what its mode says
  var setSteer: str            // the steer mode last set by set-mode!
  var setFollow: str           // the follow-up mode last set by set-mode!
  var behindEx: Set[int]       // local follow-ups offered behind an exclusive job, not yet in a turn
  // The previous state, copied each step. Refinement is a state predicate
  // over (previous, current), so the step relation carries no lineNext
  // and the base proof stays cheap; only the refinement proofs pay for it.
  var pKind: str
  var pN: int
  var pHid: int
  var pSteer: Set[int]
  var pFollowUp: Set[int]
  var pStart: bool
  var pCancel: bool
  var pWhy: int -> str
  var pWhyN: int -> int
  var pSteerMode: str
  var pFollowMode: str
  var pBody: bool
  var pSeq: int
  var pFor: int -> int
  var pIsSteer: int -> bool
  var pIsLocal: int -> bool
  var pFirstUp: int
  var pExReq: bool

  def ps: Session = {
    kind: pKind, n: pN, hid: pHid, steer: pSteer, followUp: pFollowUp, start: pStart, firstUp: pFirstUp, exReq: pExReq,
    cancel: pCancel, why: pWhy, whyN: pWhyN, steerMode: pSteerMode, followMode: pFollowMode,
  }

  action init = all {
    kind' = sessionInit.kind, n' = sessionInit.n, hid' = 0, steer' = sessionInit.steer,
    followUp' = sessionInit.followUp, start' = sessionInit.start, firstUp' = -1, exReq' = false,
    cancel' = sessionInit.cancel, why' = sessionInit.why, whyN' = sessionInit.whyN,
    body' = false, nextSeq' = 0,
    tagOf' = SEQS.mapBy(_q => 0), forTurn' = SEQS.mapBy(_q => 0),
    isSteer' = SEQS.mapBy(_q => false), isLocal' = SEQS.mapBy(_q => false),
    orderOk' = true, cancelOk' = true, leakFree' = true, behindEx' = Set(),
    steerMode' = "one", followMode' = "one",
    heldFor' = 0, waitedFor' = 0, starved' = false, takeOk' = true,
    setSteer' = "one", setFollow' = "one",
    pKind' = sessionInit.kind, pN' = sessionInit.n, pHid' = 0, pSteer' = sessionInit.steer,
    pFollowUp' = sessionInit.followUp, pStart' = sessionInit.start, pFirstUp' = -1, pExReq' = false,
    pCancel' = sessionInit.cancel, pWhy' = sessionInit.why, pWhyN' = sessionInit.whyN,
    pSteerMode' = sessionInit.steerMode, pFollowMode' = sessionInit.followMode,
    pBody' = false, pSeq' = 0, pFor' = SEQS.mapBy(_q => 0),
    pIsSteer' = SEQS.mapBy(_q => false), pIsLocal' = SEQS.mapBy(_q => false),
  }

  // ---- refinement mappings onto L0 (lease) and L1 (one line) ----

  pure def leaseOf(a: Session, b: bool): { kind: str, n: int, hid: int, body: bool, cancel: bool, startReq: bool, exReq: bool } = {
    kind: a.kind, n: a.n, hid: a.hid, body: b, cancel: a.cancel,
    startReq: a.start and a.followUp != Set(),
    exReq: a.exReq,
  }

  pure def viewOf(a: Session, b: bool, ns: int, fT: int -> int, sT: int -> bool,
                  lc: int -> bool, q: int): { lease: { kind: str, n: int, hid: int, body: bool, cancel: bool, startReq: bool, exReq: bool }, st: str, why: str, whyN: int, forTurn: int, wasSteer: bool, local: bool, steerAhead: bool, otherSteer: bool, followAhead: bool, steerMode: str, followMode: str } = {
    lease: leaseOf(a, b),
    st: if (q >= ns) "unissued" else if (a.steer.contains(q)) "steer"
        else if (a.followUp.contains(q)) "follow" else "done",
    why: a.why.get(q), whyN: a.whyN.get(q), forTurn: fT.get(q),
    wasSteer: sT.get(q), local: lc.get(q),
    steerAhead: a.steer.exists(x => x < q),
    otherSteer: a.steer.exclude(Set(q)) != Set(),
    followAhead: if (a.firstUp >= 0) a.firstUp != q
                 else a.followUp.exists(x => x < q),
    steerMode: a.steerMode, followMode: a.followMode,
  }

  // A start was asked for and is possible (the spec of "waiting", kept
  // independent of `canStartTurn`, which is the implementation's guard).
  pure def waiting(a: Session): bool =
    a.kind == "none" and a.start and a.followUp != Set() and a.n < MAX_N and a.hid < MAX_H

  // Boolean right-hand sides are parenthesized on purpose: a bare
  // `x' = a or b` inside an action is read as an action-level `or` and the
  // ghost never updates (mutants would survive).
  action go(gs: Session, gBody: bool, gSeq: int, gTag: int -> int,
            gFor: int -> int, gSteer: int -> bool, gOrder: bool, gCancel: bool): bool =
    goL(gs, gBody, gSeq, gTag, gFor, gSteer, isLocal, gOrder, gCancel, true, false,
        setSteer, setFollow)

  action goL(gs: Session, gBody: bool, gSeq: int, gTag: int -> int, gFor: int -> int,
             gSteer: int -> bool, gLocal: int -> bool, gOrder: bool, gCancel: bool,
             gTake: bool, gStarved: bool, gSetSteer: str, gSetFollow: str): bool =
    goLB(gs, gBody, gSeq, gTag, gFor, gSteer, gLocal, gOrder, gCancel, gTake, gStarved,
         gSetSteer, gSetFollow, false)

  // gBehind: this step admits a plain local offer behind an exclusive job.
  action goLB(gs: Session, gBody: bool, gSeq: int, gTag: int -> int, gFor: int -> int,
             gSteer: int -> bool, gLocal: int -> bool, gOrder: bool, gCancel: bool,
             gTake: bool, gStarved: bool, gSetSteer: str, gSetFollow: str,
             gBehind: bool): bool = all {
    kind' = gs.kind, n' = gs.n, hid' = gs.hid, steer' = gs.steer, followUp' = gs.followUp,
    start' = gs.start, firstUp' = gs.firstUp, exReq' = gs.exReq, cancel' = gs.cancel, why' = gs.why, whyN' = gs.whyN,
    steerMode' = gs.steerMode, followMode' = gs.followMode,
    body' = gBody, nextSeq' = gSeq,
    heldFor' = if (gs.kind == "none" or kind == "none") 0 else heldFor + 1,
    waitedFor' = if (waiting(gs) and waiting(s)) waitedFor + 1 else 0,
    starved' = (starved or gStarved),
    takeOk' = (takeOk and gTake),
    setSteer' = gSetSteer, setFollow' = gSetFollow,
    pKind' = kind, pN' = n, pHid' = hid, pSteer' = steer, pFollowUp' = followUp, pStart' = start,
    pFirstUp' = firstUp, pExReq' = exReq, pCancel' = cancel, pWhy' = why, pWhyN' = whyN, pSteerMode' = steerMode,
    pFollowMode' = followMode, pBody' = body, pSeq' = nextSeq, pFor' = forTurn,
    pIsSteer' = isSteer, pIsLocal' = isLocal,
    tagOf' = gTag, forTurn' = gFor, isSteer' = gSteer, isLocal' = gLocal,
    orderOk' = (orderOk and gOrder),
    behindEx' = if (gs.kind == "turn" and kind != "turn") Set()
                else (if (gBehind)
                        behindEx.union(Set(nextSeq)) else behindEx).intersect(gs.followUp),
    cancelOk' = (cancelOk and gCancel),
    leakFree' = (leakFree and (gBody or gs.kind == "none")),
  }

  action plain(ps: Session, pBody: bool): bool =
    go(ps, pBody, nextSeq, tagOf, forTurn, isSteer, true, true)

  // The driver's idle tick: next-start! then (with-holder :turn ...).
  // The whole start guard, in one place: the deadline tick below takes
  // `doStartTurn` exactly when this holds and `doStarved` otherwise, so the
  // forced step is total and a guard bug shows up as `starved`, never as a
  // silent deadlock. Keep every start condition here, not in the action.
  pure def startGuard(a: Session): bool = canStartTurn(a) and a.n < MAX_N and a.hid < MAX_H

  action doStartTurn: bool = all {
    startGuard(s),
    plain(startTurn(s), true),
  }

  // (with-holder :exclusive f): /reload, /handoff.
  action doRequestExclusive: bool = all { not(exReq), plain(requestExclusive(s), body) }

  action doStartExclusive: bool = all {
    s.kind == "none", s.exReq,
    // a pending turn start has priority over an exclusive holder
    not(s.start and s.followUp != Set()),
    s.hid < MAX_H,
    plain(startExclusive(s), true),
  }

  // The body exits: returns, raises (crash), or ends after a cancel. Every
  // path releases in the same step (with-holder's xpcall).
  action doBodyExit(crashed: bool): bool = all {
    body,
    if (crashed) bodyCrashed else plain(release(s), false),
  }

  action bodyCrashed: bool = plain(release(s), false)

  // Kept for the mutant check: a crash path that forgets to release.
  action bodyCrashedLeaks: bool = plain(s, false)

  // offer! text {:tag g :turn t :follow-up? f}; t = -1 means no :turn.
  action doOffer(t: int, g: int, f: bool): bool =
    val q = nextSeq
    val b = offer(s, q, t, f)
    all {
      nextSeq < MAX_SEQ,
      goLB(b, body, nextSeq + 1, tagOf.set(q, g),
          forTurn.set(q, if (not(b.steer.contains(q))) 0 else if (t > 0) t else s.n),
          isSteer.set(q, b.steer.contains(q)), isLocal.set(q, t == -1),
          true, true, true, false, setSteer, setFollow,
          t == -1 and not(f) and s.kind == "exclusive"),
    }

  // Exactly what the mode says: one line, or every queued line.
  pure def drainedByMode(mode: str, before: Set[int], after: Set[int]): bool =
    if (mode == "all") after == Set()
    else after.subseteq(before) and before.exclude(after).size() == 1

  action doTakeSteer: bool =
    val b = takeSteer(s)
    all {
      body, s.kind == "turn", s.steer != Set(),
      goL(b, body, nextSeq, tagOf, forTurn, isSteer, isLocal, true, true,
          drainedByMode(setSteer, s.steer, b.steer), false, setSteer, setFollow),
    }

  action doTakeFollowUp: bool =
    val b = takeFollowUp(s)
    all {
      body, s.kind == "turn", s.steer == Set(), s.followUp != Set(),
      goL(b, body, nextSeq, tagOf, forTurn, isSteer, isLocal, s.steer == Set(), true,
          drainedByMode(setFollow, s.followUp, b.followUp), false, setSteer, setFollow),
    }

  // set-mode! which mode
  action doSetMode(which: str, mode: str): bool =
    goL(setMode(s, which, mode), body, nextSeq, tagOf, forTurn, isSteer, isLocal,
        true, true, true, false,
        if (which == "steer") mode else setSteer,
        if (which == "steer") setFollow else mode)

  // The idle tick is due but cannot start a requested turn: a liveness failure.
  action doStarved: bool = all {
    not(startGuard(s)),
    goL(s, body, nextSeq, tagOf, forTurn, isSteer, isLocal, true, true, true, true,
        setSteer, setFollow),
  }

  // cancel! h, e.g. Ctrl-C that saw holder h, or a remote control.
  action doCancel(m: int): bool =
    val b = cancelHolder(s, m)
    go(b, body, nextSeq, tagOf, forTurn, isSteer, true,
       (not(b.cancel and not(s.cancel)) or m == s.hid))

  action doClearSteer: bool = all { s.steer != Set(), plain(clearSteer(s), body) }

  action doClearFollowUp: bool = all {
    s.followUp != Set() or s.start,
    plain(clearFollowUp(s), body),
  }

  action step = {
    nondet t = Set(-1, 0).union(1.to(MAX_N)).oneOf()
    nondet g = TAGVALS.oneOf()
    nondet f = Bool.oneOf()
    nondet m = HS.oneOf()
    nondet which = Set("steer", "followUp").oneOf()
    nondet mode = MODES.oneOf()
    // Fairness made explicit: an overdue body exits; an overdue idle tick
    // starts the requested turn (or is recorded as starved).
    if (body and heldFor >= MAX_BODY) doBodyExit(f)
    else if (waiting(s) and waitedFor >= MAX_IDLE) (if (startGuard(s)) doStartTurn else doStarved)
    else any {
      doStartTurn,
      doRequestExclusive,
      doStartExclusive,
      doBodyExit(f),
      doOffer(t, g, f),
      doTakeSteer,
      doTakeFollowUp,
      doCancel(m),
      doClearSteer,
      doClearFollowUp,
      doSetMode(which, mode),
    }
  }

  // ---- Properties ----

  val sessionInvHolds = sessionInv(s)

  // with-holder: a holder exists exactly while its body runs, so a crash,
  // a cancel, or a forgotten release can never wedge the session.
  val holderHasBodyInv = (s.kind != "none") == body and leakFree

  // Every admitted seq is either still queued or has exactly one disposition;
  // unissued seqs have none. (Exactly-once return, keyed by seq, not by the
  // caller's tag or text.)
  val eachSeqOnceInv = SEQS.forall(q =>
    if (q < nextSeq)
      (s.steer.contains(q) or s.followUp.contains(q)) != (s.why.get(q) != "")
    else
      not(s.steer.contains(q)) and not(s.followUp.contains(q)) and s.why.get(q) == "")

  // Fencing: queued steer lines belong to the running turn they were offered
  // for, and every steer line that left was taken or returned by that turn.
  val steerForHolderInv = and {
    s.steer.forall(q => s.kind == "turn" and forTurn.get(q) == s.n),
    SEQS.forall(q =>
      (isSteer.get(q) and (s.why.get(q) == "taken" or s.why.get(q) == "released"))
        implies s.whyN.get(q) == forTurn.get(q)),
  }

  // Only turns consume numbers, and a started line opened exactly that turn.
  val startedOpensItsTurnInv = SEQS.forall(q =>
    s.why.get(q) == "started" implies (s.whyN.get(q) >= 1 and s.whyN.get(q) <= s.n))

  // Busy-time offers without :turn are never refused (the /reload, /handoff gap).
  val localOfferNeverRefusedInv = SEQS.forall(q =>
    s.why.get(q) == "refused" implies not(isLocal.get(q)))

  val followUpOrderInv = orderOk

  // Liveness (bounded): no holder holds longer than its body may run, so a
  // leaked holder shows up as a holder held past the bound.
  val releasedInTimeInv = heldFor <= MAX_BODY

  // Liveness (bounded): a requested idle start happens within MAX_IDLE ticks.
  val startedInTimeInv = waitedFor <= MAX_IDLE and not(starved)

  // Modes: every take! drains exactly what the mode says, and modes persist
  // across turns, releases, and clears until set-mode! changes them.
  // Refinement: L2 is a correct implementation of L0 and, per seq, of L1,
  // so the lease's liveness and the line's safety carry up to this model.
  // The last step was an L0 lease step, and for every seq an L1 line step.
  val refinesLease = leaseNext(leaseOf(ps, pBody), leaseOf(s, body))
  val refinesLine = SEQS.forall(q =>
    lineNext(viewOf(ps, pBody, pSeq, pFor, pIsSteer, pIsLocal, q),
             viewOf(s, body, nextSeq, forTurn, isSteer, isLocal, q)))

  val takeByModeInv = takeOk
  // A line typed during /reload or compaction asks for a turn: it is not
  // stranded once the job ends (it starts by the idle-start bound).
  val behindExclusiveStartsInv =
    (kind != "turn" and behindEx != Set()) implies start
  val modesPersistInv = steerMode == setSteer and followMode == setFollow
  val cancelFencedInv = cancelOk

  val safetyInvariants = and {
    sessionInvHolds,
    holderHasBodyInv,
    eachSeqOnceInv,
    steerForHolderInv,
    startedOpensItsTurnInv,
    localOfferNeverRefusedInv,
    followUpOrderInv,
    cancelFencedInv,
    releasedInTimeInv,
    startedInTimeInv,
    takeByModeInv,
    behindExclusiveStartsInv,
    modesPersistInv,
  }

  // Simulation checks the refinement monitors too; the proofs split them off
  // (see verify.tsv): the per-seq lineNext monitor dominates solver time.
  val allInvariants = and { safetyInvariants, refinesLease, refinesLine }

  // Typing for the previous-state copy; nothing else is assumed about it.
  val prevTyped = and {
    pKind.in(KINDS), pN.in(NS), pHid.in(HS), pSteer.in(powerset(SEQS)), pFollowUp.in(powerset(SEQS)),
    pStart.in(Bool), pCancel.in(Bool), pWhy.in(setOfMaps(SEQS, WHYS)),
    pWhyN.in(setOfMaps(SEQS, NS)), pSteerMode.in(MODES), pFollowMode.in(MODES),
    pBody.in(Bool), pFirstUp.in(Set(-1).union(SEQS)), pExReq.in(Bool), pSeq.in(0.to(MAX_SEQ)), pFor.in(setOfMaps(SEQS, NS)),
    pIsSteer.in(setOfMaps(SEQS, Bool)), pIsLocal.in(setOfMaps(SEQS, Bool)),
  }
  val inductiveInv = and {
    prevTyped,
    kind.in(KINDS),
    n.in(NS),
    hid.in(HS),
    n <= hid,
    steer.in(powerset(SEQS)),
    followUp.in(powerset(SEQS)),
    start.in(Bool),
    cancel.in(Bool),
    why.in(setOfMaps(SEQS, WHYS)),
    whyN.in(setOfMaps(SEQS, NS)),
    body.in(Bool),
    nextSeq.in(0.to(MAX_SEQ)),
    tagOf.in(setOfMaps(SEQS, TAGVALS)),
    forTurn.in(setOfMaps(SEQS, NS)),
    isSteer.in(setOfMaps(SEQS, Bool)),
    isLocal.in(setOfMaps(SEQS, Bool)),
    orderOk.in(Bool),
    cancelOk.in(Bool),
    leakFree.in(Bool),
    steerMode.in(MODES),
    followMode.in(MODES),
    heldFor.in(0.to(MAX_BODY)),
    waitedFor.in(0.to(MAX_IDLE)),
    starved.in(Bool),
    takeOk.in(Bool),
    setSteer.in(MODES),
    setFollow.in(MODES),
    start implies followUp != Set(),
    start implies kind != "turn",
    exReq.in(Bool),
    behindEx.in(powerset(SEQS)),
    behindEx.subseteq(followUp),
    kind == "turn" implies behindEx == Set(),
    firstUp.in(Set(-1).union(SEQS)),
    start == (firstUp >= 0),
    firstUp >= 0 implies followUp.contains(firstUp),
    kind == "none" implies heldFor == 0,
    not(waiting(s)) implies waitedFor == 0,
    SEQS.forall(q => isSteer.get(q) implies forTurn.get(q) >= 1),
    SEQS.forall(q => s.steer.contains(q) implies isSteer.get(q)),
    SEQS.forall(q => s.followUp.contains(q) implies not(isSteer.get(q))),
    SEQS.forall(q => s.whyN.get(q) <= s.n),
    SEQS.forall(q => forTurn.get(q) <= s.n),
    // a seq not yet issued carries only initial values
    SEQS.forall(q => q >= nextSeq implies and {
      s.why.get(q) == "", s.whyN.get(q) == 0, forTurn.get(q) == 0, tagOf.get(q) == 0,
      not(isSteer.get(q)), not(isLocal.get(q)),
      not(s.steer.contains(q)), not(s.followUp.contains(q)) }),
    safetyInvariants,
  }

  // Refinement of L0 and, per seq, of L1, on top of the base induction.
  // Each step from a state satisfying the base invariant refines L0 / L1.
  val refinesLeaseInv = and { inductiveInv, refinesLease }
  val refinesInv = and { inductiveInv, refinesLease, refinesLine }
}
