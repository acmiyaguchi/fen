// Deterministic witnesses for the running-turn identity proof model.
module witnesses {
  import turnIdentity(FIXES = Set()) as C from "./model"
  import turnIdentity(FIXES = Set("627")) as F from "./model"

  run reachDeferredReloadAtIdleTest =
    F::init.then(F::edit("bad")).then(F::startTurn).then(F::midTurnReload)
      .then(F::turnAppend).then(F::endTurn).then(F::drainPending)
      .expect(not(F::bTool) and not(F::pending) and F::turnIdentityInductive)

  run reachNextTurnSeesReloadTest =
    F::init.then(F::edit("bad")).then(F::startTurn).then(F::midTurnReload).then(F::endTurn)
      .then(F::drainPending).then(F::startTurn)
      .expect(F::phase == "busy" and not(F::snapB) and F::turnIdentityInductive)
}
