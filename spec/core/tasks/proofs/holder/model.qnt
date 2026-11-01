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
    steer: Set[int],       // seqs of steer lines for the running turn
    followUp: Set[int],    // seqs of follow-ups
    start: bool,           // an idle offer asked next-start! to start a turn
    cancel: bool,          // cancel! n was accepted for the running turn
    steerMode: str,        // drain mode for take! :steer ("one" | "all")
    followMode: str,       // drain mode for take! :follow-up
    why: int -> str,       // seq -> disposition ("" while queued or unissued)
    whyN: int -> int,      // seq -> turn number at its disposition
  }

  pure def sessionInit: Session = {
    kind: "none", n: 0, steer: Set(), followUp: Set(), start: false, cancel: false,
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

  // next-start! + (with-holder :turn ...): the head follow-up starts turn n+1.
  pure def startTurn(a: Session): Session =
    val first = minOf(a.followUp)
    dispose({ ...a, kind: "turn", n: a.n + 1, followUp: a.followUp.exclude(Set(first)),
              start: false, cancel: false }, Set(first), "started", a.n + 1)

  pure def canStartTurn(a: Session): bool =
    a.start and a.followUp != Set() and a.kind == "none"

  // (with-holder :exclusive f): /reload, /handoff. Consumes no turn number.
  pure def startExclusive(a: Session): Session = { ...a, kind: "exclusive", cancel: false }

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
      if (a.kind == "none") { ...a, followUp: a.followUp.union(Set(s)), start: true }
      else dispose(a, Set(s), "refused", a.n)
    else if (a.kind == "turn") { ...a, steer: a.steer.union(Set(s)) }
    else if (a.kind == "exclusive") { ...a, followUp: a.followUp.union(Set(s)) }
    else { ...a, followUp: a.followUp.union(Set(s)), start: true }

  // take! :steer drains by the session's steer mode.
  pure def takeSteer(a: Session): Session =
    val taken = if (a.steerMode == "all") a.steer else Set(minOf(a.steer))
    dispose({ ...a, steer: a.steer.exclude(taken) }, taken, "taken", a.n)

  // Steering wins: follow-ups only once the turn's steer lines are drained.
  pure def takeFollowUp(a: Session): Session =
    val taken = if (a.followMode == "all") a.followUp else Set(minOf(a.followUp))
    dispose({ ...a, followUp: a.followUp.exclude(taken) }, taken, "taken", a.n)

  // cancel! m: only the running turn m.
  pure def cancelTurn(a: Session, m: int): Session =
    if (a.kind == "turn" and m == a.n) { ...a, cancel: true } else a

  // set-mode! kind mode: persists across turns, releases, and clears.
  pure def setMode(a: Session, which: str, mode: str): Session =
    if (which == "steer") { ...a, steerMode: mode } else { ...a, followMode: mode }

  pure def clearSteer(a: Session): Session =
    dispose({ ...a, steer: Set() }, a.steer, "cleared", a.n)

  pure def clearFollowUp(a: Session): Session =
    dispose({ ...a, followUp: Set(), start: false }, a.followUp, "cleared", a.n)

  // Steer lines exist only while a turn holds the session.
  pure def steerOnlyForTurn(a: Session): bool =
    a.steer != Set() implies a.kind == "turn"

  pure def sessionInv(a: Session): bool = and {
    KINDS.contains(a.kind),
    a.n >= 0,
    a.kind == "turn" implies a.n >= 1,
    a.cancel implies a.kind == "turn",
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

  pure val MAX_N = 3
  pure val NS = 0.to(MAX_N)
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
  var steer: Set[int]
  var followUp: Set[int]
  var start: bool
  var cancel: bool
  var why: int -> str
  var whyN: int -> int
  var steerMode: str
  var followMode: str

  def s: Session = {
    kind: kind, n: n, steer: steer, followUp: followUp, start: start,
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

  action init = all {
    kind' = sessionInit.kind, n' = sessionInit.n, steer' = sessionInit.steer,
    followUp' = sessionInit.followUp, start' = sessionInit.start,
    cancel' = sessionInit.cancel, why' = sessionInit.why, whyN' = sessionInit.whyN,
    body' = false, nextSeq' = 0,
    tagOf' = SEQS.mapBy(_q => 0), forTurn' = SEQS.mapBy(_q => 0),
    isSteer' = SEQS.mapBy(_q => false), isLocal' = SEQS.mapBy(_q => false),
    orderOk' = true, cancelOk' = true, leakFree' = true,
    steerMode' = "one", followMode' = "one",
    heldFor' = 0, waitedFor' = 0, starved' = false, takeOk' = true,
    setSteer' = "one", setFollow' = "one",
  }

  // A start was asked for and is possible (the spec of "waiting", kept
  // independent of `canStartTurn`, which is the implementation's guard).
  pure def waiting(a: Session): bool =
    a.kind == "none" and a.start and a.followUp != Set() and a.n < MAX_N

  // Boolean right-hand sides are parenthesized on purpose: a bare
  // `x' = a or b` inside an action is read as an action-level `or` and the
  // ghost never updates (mutants would survive).
  action go(gs: Session, gBody: bool, gSeq: int, gTag: int -> int,
            gFor: int -> int, gSteer: int -> bool, gOrder: bool, gCancel: bool): bool =
    goL(gs, gBody, gSeq, gTag, gFor, gSteer, isLocal, gOrder, gCancel, true, false,
        setSteer, setFollow)

  action goL(gs: Session, gBody: bool, gSeq: int, gTag: int -> int, gFor: int -> int,
             gSteer: int -> bool, gLocal: int -> bool, gOrder: bool, gCancel: bool,
             gTake: bool, gStarved: bool, gSetSteer: str, gSetFollow: str): bool = all {
    kind' = gs.kind, n' = gs.n, steer' = gs.steer, followUp' = gs.followUp,
    start' = gs.start, cancel' = gs.cancel, why' = gs.why, whyN' = gs.whyN,
    steerMode' = gs.steerMode, followMode' = gs.followMode,
    body' = gBody, nextSeq' = gSeq,
    heldFor' = if (gs.kind == "none" or kind == "none") 0 else heldFor + 1,
    waitedFor' = if (waiting(gs) and waiting(s)) waitedFor + 1 else 0,
    starved' = (starved or gStarved),
    takeOk' = (takeOk and gTake),
    setSteer' = gSetSteer, setFollow' = gSetFollow,
    tagOf' = gTag, forTurn' = gFor, isSteer' = gSteer, isLocal' = gLocal,
    orderOk' = (orderOk and gOrder),
    cancelOk' = (cancelOk and gCancel),
    leakFree' = (leakFree and (gBody or gs.kind == "none")),
  }

  action plain(ps: Session, pBody: bool): bool =
    go(ps, pBody, nextSeq, tagOf, forTurn, isSteer, true, true)

  // The driver's idle tick: next-start! then (with-holder :turn ...).
  action doStartTurn: bool = all {
    canStartTurn(s), s.n < MAX_N,
    plain(startTurn(s), true),
  }

  // (with-holder :exclusive f): /reload, /handoff.
  action doStartExclusive: bool = all {
    s.kind == "none",
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
      goL(b, body, nextSeq + 1, tagOf.set(q, g),
          forTurn.set(q, if (not(b.steer.contains(q))) 0 else if (t > 0) t else s.n),
          isSteer.set(q, b.steer.contains(q)), isLocal.set(q, t == -1 and not(f)),
          true, true, true, false, setSteer, setFollow),
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
    not(canStartTurn(s)),
    goL(s, body, nextSeq, tagOf, forTurn, isSteer, isLocal, true, true, true, true,
        setSteer, setFollow),
  }

  // cancel! m, e.g. a remote control that saw turn m.
  action doCancel(m: int): bool =
    val b = cancelTurn(s, m)
    go(b, body, nextSeq, tagOf, forTurn, isSteer, true,
       (not(b.cancel and not(s.cancel)) or m == s.n))

  action doClearSteer: bool = all { s.steer != Set(), plain(clearSteer(s), body) }

  action doClearFollowUp: bool = all {
    s.followUp != Set() or s.start,
    plain(clearFollowUp(s), body),
  }

  action step = {
    nondet t = Set(-1, 0).union(1.to(MAX_N)).oneOf()
    nondet g = TAGVALS.oneOf()
    nondet f = Bool.oneOf()
    nondet m = NS.oneOf()
    nondet which = Set("steer", "followUp").oneOf()
    nondet mode = MODES.oneOf()
    // Fairness made explicit: an overdue body exits; an overdue idle tick
    // starts the requested turn (or is recorded as starved).
    if (body and heldFor >= MAX_BODY) doBodyExit(f)
    else if (waiting(s) and waitedFor >= MAX_IDLE) any { doStartTurn, doStarved }
    else any {
      doStartTurn,
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
  val takeByModeInv = takeOk
  val modesPersistInv = steerMode == setSteer and followMode == setFollow
  val cancelFencedInv = cancelOk

  val allInvariants = and {
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
    modesPersistInv,
  }

  val inductiveInv = and {
    kind.in(KINDS),
    n.in(NS),
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
    kind == "none" implies heldFor == 0,
    not(waiting(s)) implies waitedFor == 0,
    SEQS.forall(q => isSteer.get(q) implies forTurn.get(q) >= 1),
    SEQS.forall(q => s.steer.contains(q) implies isSteer.get(q)),
    SEQS.forall(q => s.followUp.contains(q) implies not(isSteer.get(q))),
    SEQS.forall(q => s.whyN.get(q) <= s.n),
    SEQS.forall(q => forTurn.get(q) <= s.n),
    allInvariants,
  }
}
