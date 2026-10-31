// Deterministic witnesses for the pump proof model.
module witnesses {
  import pump(FIXES = Set("635", "637")) as F from "./model"

  // ---- reachability of the fixed design ----

  run reachBadRowIsolatedTest =
    F::init.then(F::submitMain).then(F::emitBadRow)
      .then(F::iterate(false, false, true, false))
      .expect(F::s.loop == "running" and not(F::s.busy) and F::pumpInductive)

  run reachBgTaskFinishesActiveTest =
    F::init.then(F::startBgTask).then(F::startBgTask)
      .then(F::iterate(false, true, false, false)).then(F::iterate(false, true, false, false))
      .expect(F::s.bgTasks == 0 and F::s.lastBgGap == F::ACTIVE_MS and F::pumpInductive)

  run reachIdlePollWithNothingPendingTest =
    F::init.then(F::submitSide).then(F::iterate(false, false, false, true))
      .then(F::iterate(false, false, false, false))
      .expect(not(F::s.sideAlive) and F::s.lastBgGap == 0 and F::pumpInductive)
}
