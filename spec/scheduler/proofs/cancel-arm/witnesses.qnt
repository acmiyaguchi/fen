// Deterministic witnesses for the cancel-arm proof model.
module witnesses {
  import cancelArm(FIXES = Set("636")) as F from "./model"

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
