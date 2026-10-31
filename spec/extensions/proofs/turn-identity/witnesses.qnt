// Deterministic witnesses for the running-turn identity proof model.
module witnesses {
  import turnIdentity(FIXES = Set()) as C from "./model"
  import turnIdentity(FIXES = Set("627")) as F from "./model"

  run w627MidTurnAgentSwapTest =
    C::init.then(C::startTurn).then(C::midTurnReload)
      .expect(not(C::noRegistrySwapDuringTurn) and C::swapped)

  run w627TurnToolsUnregisteredTest =
    C::init.then(C::edit("bad")).then(C::startTurn).then(C::midTurnReload)
      .expect(not(C::turnToolsLive) and C::snapB and not(C::bTool))

  run w627TurnMessagesUnflushedTest =
    C::init.then(C::startTurn).then(C::midTurnReload).then(C::turnAppend).then(C::endTurn)
      .expect(not(C::turnMessagesPersisted) and C::unflushed)

  run reachDeferredReloadAtIdleTest =
    F::init.then(F::edit("bad")).then(F::startTurn).then(F::midTurnReload)
      .then(F::turnAppend).then(F::endTurn).then(F::drainPending)
      .expect(not(F::bTool) and not(F::pending) and F::turnIdentityInductive)

  run reachNextTurnSeesReloadTest =
    F::init.then(F::edit("bad")).then(F::startTurn).then(F::midTurnReload).then(F::endTurn)
      .then(F::drainPending).then(F::startTurn)
      .expect(F::phase == "busy" and not(F::snapB) and F::turnIdentityInductive)
}
