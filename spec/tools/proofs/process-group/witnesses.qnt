// Deterministic witnesses for the process-group proof model.
module witnesses {
  import processGroup(FIXES = Set("651")) as C from "./model"
  import processGroup(FIXES = Set("651")) as F from "./model"



  run reachCleanExitTest =
    F::init.then(F::startWith(false, false)).then(F::leaderExit)
      .then(F::memberExit).then(F::finish)
      .expect(F::done and not(F::killSent) and F::inductiveInv)

  run reachTimeoutGraceKillTest =
    F::init.then(F::startWith(true, true)).then(F::deadline).then(F::grace)
      .then(F::finish)
      .expect(F::done and F::timedOut and F::killSent and F::inductiveInv)

  run reachTimeoutKillAtFinishTest =
    F::init.then(F::startWith(false, true)).then(F::deadline).then(F::finish)
      .expect(F::done and F::killSent and not(F::memberAlive) and F::inductiveInv)

  run reachCancelAfterReapTest =
    F::init.then(F::startWith(false, false)).then(F::leaderExit)
      .then(F::cancel).then(F::finish)
      .expect(F::cancelled and not(F::memberAlive) and F::inductiveInv)

  // A member may outlive a *normal* exit (a server started with &): allowed.
  run reachNormalExitLeavesBackgroundTest =
    F::init.then(F::startWith(false, false)).then(F::leaderExit).then(F::finish)
      .expect(F::done and F::memberAlive and F::inductiveInv)
}
