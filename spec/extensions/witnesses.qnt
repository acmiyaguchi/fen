// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows a case the `fixed` invariants rely on is reachable.
module witnesses {
  import extensions(FIXES = Set()) as C from "./model"
  import extensions(FIXES = Set("624", "625", "626", "627", "628")) as F from "./model"

  // ---- reachability of the fixed design ----

  // A failed module leaves A :stale with its registrations; B still reloads.
  run reachFailedReloadKeepsStaleTest =
    F::init.then(F::edit("A", "badModule")).then(F::reloadAll)
      .expect(F::status.get("A") == "stale" and F::visited == F::OWNERS
              and F::reg.cmds.get("reload") == "A" and F::allInvariants)

  // Fixing the source and reloading brings A back to :loaded.
  run reachRepairAfterFailureTest =
    F::init.then(F::edit("A", "badRegister")).then(F::reloadAll)
      .then(F::edit("A", "ok")).then(F::reloadAll)
      .expect(F::status.get("A") == "loaded" and F::allInvariants)

  // A second /reload retries the broken module instead of skipping it.
  run reachFingerprintRetriedTest =
    F::init.then(F::edit("B", "badModule")).then(F::reloadAll).then(F::reloadAll)
      .expect(F::status.get("B") == "stale" and F::tried.get("B") == "badModule"
              and F::allInvariants)

  // /reload-extension A keeps fresh-start order and winners.
  run reachReloadOneKeepsOrderTest =
    F::init.then(F::reloadOne("A"))
      .expect(F::reg.cmds.get("dup") == "B" and F::reg.tools == ["A", "B"] and F::allInvariants)

  // Unloading B mid-emit exposes A's claim on the shared name.
  run reachUnloadExposesOtherClaimTest =
    F::init.then(F::emit(true))
      .expect(F::reg.cmds.get("dup") == "A" and F::status.get("B") == "disabled"
              and F::allInvariants)

  // A mid-turn reload is queued, the turn's messages are flushed, and the
  // reload runs at the idle boundary.
  run reachDeferredReloadDrainedTest =
    F::init.then(F::startTurn).then(F::midTurnReload("A")).then(F::turnAppend)
      .then(F::endTurn).then(F::drainPending)
      .expect(F::pending == List() and F::agentId == 1 and F::unflushed == 0
              and F::allInvariants)
}
