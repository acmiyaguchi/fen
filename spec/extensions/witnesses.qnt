// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows a case the `fixed` invariants rely on is reachable.
module witnesses {
  import extensions(FIXES = Set()) as C from "./model"
  import extensions(FIXES = Set("624", "625", "626", "627", "628")) as F from "./model"

  // #624: A's reload module fails: A is unregistered and loses its status
  // record, the raise aborts the pass before B, and /reload is gone.
  run w624ModuleErrorAbortsPassTest =
    C::init.then(C::edit("A", "badModule")).then(C::reloadAll)
      .expect(not(C::reloadVisitsEveryOwner) and not(C::attemptedOwnerListed)
              and not(C::reloadCommandAvailable)
              and C::status.get("A") == "none" and not(C::visited.contains("B")))

  // #625: the failed module's fingerprint was committed, so the next /reload
  // skips it and reports the old code as :loaded.
  run w625FingerprintRetrySkippedTest =
    C::init.then(C::edit("B", "badModule")).then(C::reloadAll).then(C::reloadAll)
      .expect(not(C::loadedStatusTruthful) and C::status.get("B") == "loaded"
              and C::tried.get("B") == "badModule" and C::src.get("B") == "badModule")

  // #626: /reload-extension of the shadowed owner takes the shared name.
  run w626ReloadOneMovesWinnerTest =
    C::init.then(C::reloadOne("A"))
      .expect(not(C::registryMatchesFreshStart) and C::reg.cmds.get("dup") == "A"
              and C::reg.tools == ["B", "A"])

  // #626: unloading the winner drops the name the other owner still claims.
  run w626UnloadDropsSharedNameTest =
    C::init.then(C::emit(true))
      .expect(not(C::registryMatchesFreshStart) and C::reg.cmds.get("dup") == ""
              and C::status.get("A") == "loaded")

  // #627: the extension tool reloads mid-turn and replaces state.agent ...
  run w627MidTurnAgentSwapTest =
    C::init.then(C::startTurn).then(C::midTurnReload("A"))
      .expect(not(C::noRegistrySwapDuringTurn) and C::agentId == 1 and C::turnAgent == 0)

  // ... a failed mid-turn reload leaves the turn calling unregistered tools ...
  run w627TurnToolsUnregisteredTest =
    C::init.then(C::edit("A", "badModule")).then(C::startTurn).then(C::midTurnReload("A"))
      .expect(not(C::turnToolsLive) and C::turnTools == ["A", "B"] and C::reg.tools == ["B"])

  // ... and the rest of the turn's messages are never flushed.
  run w627TurnMessagesUnflushedTest =
    C::init.then(C::startTurn).then(C::midTurnReload("A")).then(C::turnAppend).then(C::endTurn)
      .expect(not(C::turnMessagesPersisted) and C::unflushed == 1)

  // #628: a tool without :execute registers.
  run w628ToolWithoutExecuteTest =
    C::init.then(C::registerMalformed("tool"))
      .expect(not(C::registeredCallablesPresent))

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
