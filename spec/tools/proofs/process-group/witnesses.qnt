// Deterministic witnesses for the process-group proof model.
module witnesses {
  import processGroup(FIXES = Set()) as C from "./model"
  import processGroup(FIXES = Set("651")) as F from "./model"

  // #651: SIGTERM kills the leader, the TERM-ignoring member survives, and
  // the job returns without SIGKILL.
  run w651TermIgnoringMemberSurvivesTest =
    C::init.then(C::startWith(false, true)).then(C::deadline).then(C::finish)
      .expect(not(C::noLiveProcessAfterAbnormalEnd) and not(C::killSent))

  // #651, cancel variant: a cancel after the leader is reaped kills nothing.
  run w651CancelAfterReapMissesMemberTest =
    C::init.then(C::startWith(false, false)).then(C::leaderExit)
      .then(C::cancel).then(C::finish)
      .expect(not(C::noLiveProcessAfterAbnormalEnd) and not(C::killSent))

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
