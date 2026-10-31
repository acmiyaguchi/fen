// The abstract close-turn machine (#668), checked on its own: every move a
// turn owner can make, with no transcript. Its invariants hold at any depth
// (verify.tsv: inductive), so every concrete model that refines absNext
// inherits them. The replay laws live in spec/core/replay.
module turnSpec {
  import turnAbstract.* from "./abstract"

  pure val MAX_CALLS = 2
  // Call ids only need to be told apart within one reply; none of the
  // invariants depends on them being fresh, so they come from a small set
  // (which keeps every state in a finite set, as induction needs).
  pure val IDS = Set(0, 1, 2)
  pure val CALL_LISTS: Set[List[int]] =
    Set(NONE).union(IDS.map(x => [x]))
      .union(tuples(IDS, IDS).filter(p => p._1 != p._2).map(p => [p._1, p._2]))
  pure val ABS_STATES: Set[Abs] =
    CALL_LISTS.map(o => Bool.map(t => Bool.map(w =>
      Set("none", "ok", "error", "cancelled").map(oc => Bool.map(e => Bool.map(r =>
        { open: o, turnOpen: t, awaiting: w, outcome: oc, errSignalled: e, replies: r }
      )).flatten()).flatten()).flatten()).flatten()).flatten()

  var a: Abs
  var prev: Abs        // ghost: the state before the last step

  action init = all { a' = absInit, prev' = absInit }

  action move(b: Abs): bool = all { a' = b, prev' = a }

  action doUserInput = all {
    a.open == NONE,
    move({ ...a, open: NONE, turnOpen: true, awaiting: true, outcome: "none",
           errSignalled: a.turnOpen and a.errSignalled }),
  }

  action doReply(cs: List[int]): bool = all {
    a.turnOpen, a.awaiting, a.open == NONE,
    move({ ...a, open: cs, awaiting: false, replies: not(a.replies) }),
  }

  action doAnswer(k: int): bool = all {
    a.turnOpen, 1 <= k, k <= a.open.length(),
    val rest = a.open.slice(k, a.open.length())
    move({ ...a, open: rest, awaiting: rest == NONE }),
  }

  action doSignalError = all {
    a.turnOpen,
    move({ ...a, errSignalled: true }),
  }

  action doClose(o: str): bool = all {
    a.turnOpen,
    o != "ok" or (a.open == NONE and not(a.awaiting)),
    move({ ...a, open: NONE, turnOpen: false, outcome: o,
           awaiting: a.awaiting or a.open != NONE,
           errSignalled: a.errSignalled or o == "error" }),
  }

  action step = any {
    doUserInput,
    nondet cs = CALL_LISTS.oneOf()
    doReply(cs),
    nondet k = 1.to(MAX_CALLS).oneOf()
    doAnswer(k),
    doSignalError,
    nondet o = OUTCOMES.oneOf()
    doClose(o),
  }

  // ---- properties ----

  // The moves above are exactly abstract steps (the relation concrete models
  // are checked against is not stricter than this machine, or looser).
  val movesAreAbsSteps = absNext(prev, a)

  // What every refining owner inherits.
  val closedPairedInv = closedPaired(a)
  val outcomeWhenClosedInv = outcomeWhenClosed(a)
  val errorAnnouncedInv = errorAnnounced(a)
  val notAwaitingWithOpenInv = notAwaitingWithOpen(a)

  // Inductive invariant: every state is in the finite state space (which
  // Apalache needs to start from an arbitrary state) and satisfies the
  // abstract invariants. It holds initially and every step preserves it.
  val inductiveInv = and {
    a.in(ABS_STATES),
    prev.in(ABS_STATES),
    absInv(a),
  }

  val allInvariants = and {
    movesAreAbsSteps, closedPairedInv, outcomeWhenClosedInv, errorAnnouncedInv,
    notAwaitingWithOpenInv, inductiveInv,
  }
}
