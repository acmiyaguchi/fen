// Reachability of the abstract extension contribution machine (#673).
module witnesses {
  import contribAbstract.* from "./abstract"
  import contribSpec as C from "./model"

  // Mid-turn reload is deferred and drained at the idle boundary; snapshot is preserved during the turn.
  run reachTurnPreservesSnapshotTest =
    C::init.then(C::doTurnStart).then(C::doRequestMidTurn)
      .then(C::doTurnEnd).then(C::doDrainPending(true, true))
      .expect(C::a.phase == "idle" and not(C::a.pending) and C::allInvariants)

  // Failed reload of a serving extension rolls back to stale and remains serving.
  run reachRollbackToStaleTest =
    C::init.then(C::doReloadIdle("B", false))
      .expect(C::a.stB == "stale" and serves(C::a.stB) and C::allInvariants)

  // Disabling an extension at idle drops its contribution from the registry.
  run reachDisableBTest =
    C::init.then(C::doDisableB)
      .expect(C::a.stB == "disabled" and C::a.reg.order == "A" and C::allInvariants)

  // Fresh reload of all extensions at idle preserves fresh-start order.
  run reachReloadAllIdleTest =
    C::init.then(C::doReloadIdle("A", true)).then(C::doReloadIdle("B", true))
      .expect(C::a.reg.order == "AB" and C::allInvariants)
}
