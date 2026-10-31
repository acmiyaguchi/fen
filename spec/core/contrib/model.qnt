// The abstract extension contribution machine (#673), checked on its own.
// Its invariants hold inductively (verify.tsv), so every concrete model
// that refines absNext inherits them.
module contribSpec {
  import contribAbstract.* from "./abstract"

  pure val PHASES: Set[str] = Set("idle", "busy")
  pure val STA_VALUES: Set[str] = Set("loaded", "stale")
  pure val STB_VALUES: Set[str] = Set("loaded", "stale", "error", "disabled")

  pure val ABS_STATES: Set[Abs] =
    tuples(PHASES, STA_VALUES, STB_VALUES, Bool).map(t =>
      val r = view(serves(t._2), serves(t._3))
      { phase: t._1, stA: t._2, stB: t._3, reg: r, snap: r, pending: t._4 }
    )

  var a: Abs
  var prev: Abs

  action init = all { a' = absInit, prev' = absInit }

  action move(b: Abs): bool = all { a' = b, prev' = a }

  action doTurnStart = all {
    a.phase == "idle",
    move({ ...a, phase: "busy", snap: a.reg }),
  }

  action doTurnEnd = all {
    a.phase == "busy",
    move({ ...a, phase: "idle" }),
  }

  action doReloadIdle(owner: str, success: bool): bool = all {
    a.phase == "idle",
    val nextStA =
      if (owner == "A") (if (success) "loaded" else (if (serves(a.stA)) "stale" else "error"))
      else a.stA
    val nextStB =
      if (owner == "B") (if (success) "loaded" else (if (serves(a.stB)) "stale" else "error"))
      else a.stB
    val nextReg = view(serves(nextStA), serves(nextStB))
    move({ ...a, stA: nextStA, stB: nextStB, reg: nextReg, snap: nextReg }),
  }

  action doRequestMidTurn = all {
    a.phase == "busy",
    move({ ...a, pending: true }),
  }

  action doDrainPending(successA: bool, successB: bool): bool = all {
    a.phase == "idle",
    a.pending,
    val nextStA = if (successA) "loaded" else (if (serves(a.stA)) "stale" else "error")
    val nextStB = if (successB) "loaded" else (if (serves(a.stB)) "stale" else "error")
    val nextReg = view(serves(nextStA), serves(nextStB))
    move({ ...a, stA: nextStA, stB: nextStB, reg: nextReg, snap: nextReg, pending: false }),
  }

  action doDisableB = all {
    a.phase == "idle",
    serves(a.stB),
    val nextReg = view(serves(a.stA), false)
    move({ ...a, stB: "disabled", reg: nextReg, snap: nextReg }),
  }

  action step = any {
    doTurnStart,
    doTurnEnd,
    nondet o = Set("A", "B").oneOf()
    nondet s = Bool.oneOf()
    doReloadIdle(o, s),
    doRequestMidTurn,
    nondet sa = Bool.oneOf()
    nondet sb = Bool.oneOf()
    doDrainPending(sa, sb),
    doDisableB,
  }

  // ---- properties ----

  val movesAreAbsSteps = absNext(prev, a)
  val registryMatchesFreshStartInv = registryMatchesFreshStart(a)
  val noSwapDuringTurnInv = noSwapDuringTurn(a)
  val reloadCommandAvailableInv = reloadCommandAvailable(a)
  val coreOwnerServingInv = coreOwnerServing(a)

  val inductiveInv = and {
    a.in(ABS_STATES),
    prev.in(ABS_STATES),
    absInv(a),
  }

  val allInvariants = and {
    movesAreAbsSteps,
    registryMatchesFreshStartInv,
    noSwapDuringTurnInv,
    reloadCommandAvailableInv,
    coreOwnerServingInv,
    inductiveInv,
  }
}
