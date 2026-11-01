// Reachability for the lease (L0): each lifecycle case actually happens.
module witnesses {
  import leaseSpec as L from "./model"

  run reachTurnStartsAndReleasesTest =
    L::init.then(L::doRequestStart).then(L::doStartTurn).then(L::doBodyExit)
      .expect(L::kind == "none" and L::n == 1 and L::allInvariants)

  run reachExclusiveTakesNoNumberTest =
    L::init.then(L::doRequestExclusive).then(L::doStartExclusive).then(L::doBodyExit)
      .expect(L::kind == "none" and L::n == 0 and L::allInvariants)

  run reachCancelFencedTest =
    L::init.then(L::doRequestStart).then(L::doStartTurn).then(L::doCancel(2)).then(L::doCancel(1))
      .expect(L::cancel and L::allInvariants)

  run reachBodyBoundForcesReleaseTest =
    L::init.then(L::doRequestStart).then(L::doStartTurn)
      .then(L::doCancel(0)).then(L::doCancel(0)).then(L::doCancel(0)).then(L::doCancel(0))
      .then(L::step)
      .expect(L::kind == "none" and L::allInvariants)

  // A turn requested behind an exclusive job starts once the job releases.
  run reachStartBehindExclusiveTest =
    L::init.then(L::doRequestExclusive).then(L::doStartExclusive).then(L::doRequestStart)
      .then(L::doBodyExit).then(L::doStartTurn)
      .expect(L::kind == "turn" and L::n == 1 and L::allInvariants)

  // A pending turn start goes ahead of a requested exclusive job.
  run reachTurnBeforeRequestedExclusiveTest =
    L::init.then(L::doRequestExclusive).then(L::doRequestStart).then(L::doStartTurn)
      .then(L::doBodyExit).then(L::doStartExclusive)
      .expect(L::kind == "exclusive" and L::n == 1 and not(L::exReq) and L::allInvariants)
}
