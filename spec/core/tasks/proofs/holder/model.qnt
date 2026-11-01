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

  type Session = {
    kind: str,             // holder kind
    n: int,                // current (or last) turn number
    steer: Set[int],       // seqs of steer lines for the running turn
    followUp: Set[int],    // seqs of follow-ups
    start: bool,           // an idle offer asked next-start! to start a turn
    cancel: bool,          // cancel! n was accepted for the running turn
    why: int -> str,       // seq -> disposition ("" while queued or unissued)
    whyN: int -> int,      // seq -> turn number at its disposition
  }

  pure def sessionInit: Session = {
    kind: "none", n: 0, steer: Set(), followUp: Set(), start: false, cancel: false,
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
    a.kind == "none" and a.start and a.followUp != Set()

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

  pure def takeSteer(a: Session, drainAll: bool): Session =
    val taken = if (drainAll) a.steer else Set(minOf(a.steer))
    dispose({ ...a, steer: a.steer.exclude(taken) }, taken, "taken", a.n)

  // Steering wins: follow-ups only once the turn's steer lines are drained.
  pure def takeFollowUp(a: Session, drainAll: bool): Session =
    val taken = if (drainAll) a.followUp else Set(minOf(a.followUp))
    dispose({ ...a, followUp: a.followUp.exclude(taken) }, taken, "taken", a.n)

  // cancel! m: only the running turn m.
  pure def cancelTurn(a: Session, m: int): Session =
    if (a.kind == "turn" and m == a.n) { ...a, cancel: true } else a

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

  // The Session record, split into variables so Apalache can bound each one.
  var kind: str
  var n: int
  var steer: Set[int]
  var followUp: Set[int]
  var start: bool
  var cancel: bool
  var why: int -> str
  var whyN: int -> int

  def s: Session = {
    kind: kind, n: n, steer: steer, followUp: followUp, start: start,
    cancel: cancel, why: why, whyN: whyN,
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

  action init = all {
    kind' = sessionInit.kind, n' = sessionInit.n, steer' = sessionInit.steer,
    followUp' = sessionInit.followUp, start' = sessionInit.start,
    cancel' = sessionInit.cancel, why' = sessionInit.why, whyN' = sessionInit.whyN,
    body' = false, nextSeq' = 0,
    tagOf' = SEQS.mapBy(_q => 0), forTurn' = SEQS.mapBy(_q => 0),
    isSteer' = SEQS.mapBy(_q => false), isLocal' = SEQS.mapBy(_q => false),
    orderOk' = true, cancelOk' = true, leakFree' = true,
  }

  // Boolean right-hand sides are parenthesized on purpose: a bare
  // `x' = a or b` inside an action is read as an action-level `or` and the
  // ghost never updates (mutants would survive).
  action go(gs: Session, gBody: bool, gSeq: int, gTag: int -> int,
            gFor: int -> int, gSteer: int -> bool, gOrder: bool, gCancel: bool): bool =
    goL(gs, gBody, gSeq, gTag, gFor, gSteer, isLocal, gOrder, gCancel)

  action goL(gs: Session, gBody: bool, gSeq: int, gTag: int -> int, gFor: int -> int,
             gSteer: int -> bool, gLocal: int -> bool, gOrder: bool, gCancel: bool): bool = all {
    kind' = gs.kind, n' = gs.n, steer' = gs.steer, followUp' = gs.followUp,
    start' = gs.start, cancel' = gs.cancel, why' = gs.why, whyN' = gs.whyN,
    body' = gBody, nextSeq' = gSeq,
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
          true, true),
    }

  action doTakeSteer(drainAll: bool): bool = all {
    body, s.kind == "turn", s.steer != Set(),
    plain(takeSteer(s, drainAll), body),
  }

  action doTakeFollowUp(drainAll: bool): bool = all {
    body, s.kind == "turn", s.steer == Set(), s.followUp != Set(),
    go(takeFollowUp(s, drainAll), body, nextSeq, tagOf, forTurn, isSteer,
       s.steer == Set(), true),
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
    any {
      doStartTurn,
      doStartExclusive,
      doBodyExit(f),
      doOffer(t, g, f),
      doTakeSteer(f),
      doTakeFollowUp(f),
      doCancel(m),
      doClearSteer,
      doClearFollowUp,
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
    SEQS.forall(q => isSteer.get(q) implies forTurn.get(q) >= 1),
    SEQS.forall(q => s.steer.contains(q) implies isSteer.get(q)),
    SEQS.forall(q => s.followUp.contains(q) implies not(isSteer.get(q))),
    SEQS.forall(q => s.whyN.get(q) <= s.n),
    SEQS.forall(q => forTurn.get(q) <= s.n),
    allInvariants,
  }
}
