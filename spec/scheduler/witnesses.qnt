// Deterministic witnesses (quint test). Each reach...Test shows a case the
// `fixed` invariants rely on is reachable.
//
// iterate(ev, mainOutcome, sideOutcome, nextTurn, bgFinish) is one pass of
// M.run; pumpModal(...) is one select-overlay pump.
module witnesses {
  import scheduler(FIXES = Set("635", "636", "637")) as F from "./model"

  // ---- reachability of the fixed design ----

  // A turn runs to completion and the loop goes idle.
  run reachTurnCompletesTest =
    F::init.then(F::iterate("submit", "yield", "yield", false, false))
      .then(F::iterate("none", "finish", "yield", false, false))
      .expect(not(F::s.busy) and F::s.mainGen == 1 and F::allInvariants)

  // Ctrl-C cancels the running agent turn within the same pass.
  run reachCancelTest =
    F::init.then(F::iterate("submit", "yield", "yield", false, false))
      .then(F::iterate("ctrlC", "yield", "yield", false, false))
      .expect(not(F::s.busy) and not(F::s.cancelPressed) and F::allInvariants)

  // The same-tick reload start still happens, with the arm cleared.
  run reachSameTickReloadDisarmedTest =
    F::init.then(F::iterate("submit", "yield", "yield", false, false))
      .then(F::agentQueuesReload)
      .then(F::iterate("ctrlC", "yield", "yield", false, false))
      .expect(F::s.mainKind == "reload" and F::s.busy and not(F::s.cancelPressed)
              and F::allInvariants)

  // The two-press force quit still works on the turn it was armed on.
  run reachForceQuitOwnTurnTest =
    F::init.then(F::iterate("submit", "yield", "yield", false, false))
      .then(F::agentQueuesReload)
      .then(F::iterate("ctrlC", "yield", "yield", false, false))
      .then(F::iterate("ctrlC", "yield", "yield", false, false))
      .then(F::iterate("ctrlC", "yield", "yield", false, false))
      .expect(F::s.quit == "forceOwn" and F::s.loop == "exited" and F::allInvariants)

  // A bad row no longer ends the loop; the turn keeps running.
  run reachBadRowSurvivedTest =
    F::init.then(F::iterate("submit", "yield", "yield", false, false))
      .then(F::emitBadRow).then(F::iterate("none", "yield", "yield", false, false))
      .expect(F::s.loop == "running" and F::s.busy and F::allInvariants)

  // A background task is polled at the active cadence and finishes.
  run reachBgTaskFinishesActiveTest =
    F::init.then(F::startBgTask).then(F::iterate("none", "yield", "yield", false, true))
      .expect(F::s.bgTasks == 0 and F::s.lastBgGap == F::ACTIVE_MS and F::allInvariants)

  // The modal pump finalizes a turn, and a side turn runs beside it.
  run reachModalPumpAndSideTest =
    F::init.then(F::iterate("submit", "yield", "yield", false, false))
      .then(F::submitSide)
      .then(F::pumpModal("finish", "yield", false, false))
      .then(F::iterate("none", "yield", "finish", false, false))
      .expect(not(F::s.busy) and not(F::s.sideAlive) and F::allInvariants)
}
