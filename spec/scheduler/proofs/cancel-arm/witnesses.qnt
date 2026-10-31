// Deterministic witnesses for the cancel-arm proof model.
module witnesses {
  import cancelArm(FIXES = Set()) as C from "./model"
  import cancelArm(FIXES = Set("636")) as F from "./model"

  // #636: the arm survives the same-tick reload start ...
  run w636ArmOutlivesTurnTest =
    C::init.then(C::iterate("submit", "yield", false)).then(C::agentQueuesReload)
      .then(C::iterate("ctrlC", "yield", false))
      .expect(not(C::cancelArmMatchesTurn) and C::s.kind == "reload" and C::s.pressGen == 1)

  // #636: ... and the next Ctrl-C force-quits the fresh turn.
  run w636ForceQuitFreshTurnTest =
    C::init.then(C::iterate("submit", "yield", false)).then(C::agentQueuesReload)
      .then(C::iterate("ctrlC", "yield", false)).then(C::iterate("ctrlC", "yield", false))
      .expect(not(C::forceQuitOnlyOnArmedTurn) and C::s.quit == "forceFresh")

  // #636 via the modal pump: Ctrl-C on a /reload turn arms the ladder (the
  // reload ignores the cancel); the select overlay's pump finishes the reload
  // and starts a goal continuation, and no bottom reset runs in between.
  run w636ModalPumpPathTest =
    C::init.then(C::iterate("submit", "yield", false)).then(C::agentQueuesReload)
      .then(C::iterate("none", "finish", false))
      .then(C::iterate("ctrlC", "yield", false))
      .then(C::pumpModal("finish", true))
      .expect(not(C::cancelArmMatchesTurn) and C::s.kind == "agent"
              and C::s.pressGen == 2 and C::s.gen == 3)

  // ---- reachability of the fixed design ----

  run reachCancelThenReloadTest =
    F::init.then(F::iterate("submit", "yield", false)).then(F::agentQueuesReload)
      .then(F::iterate("ctrlC", "yield", false))
      .expect(F::s.kind == "reload" and not(F::s.armed) and F::armInductive)

  run reachForceQuitOwnTurnTest =
    F::init.then(F::iterate("submit", "yield", false)).then(F::agentQueuesReload)
      .then(F::iterate("ctrlC", "yield", false)).then(F::iterate("ctrlC", "yield", false))
      .then(F::iterate("ctrlC", "yield", false))
      .expect(F::s.quit == "forceOwn" and F::armInductive)

  run reachGoalContinuationTest =
    F::init.then(F::iterate("submit", "yield", false)).then(F::pumpModal("finish", true))
      .expect(F::s.kind == "agent" and F::s.gen == 2 and F::armInductive)
}
