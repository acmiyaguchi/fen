// Reachability for the lease (L0): each lifecycle case actually happens.
module witnesses {
  import leaseSpec as L from "./model"

  run reachTurnStartsAndReleasesTest =
    L::init.then(L::doRequestStart).then(L::doStartTurn).then(L::doBodyExit)
      .expect(L::kind == "none" and L::n == 1 and L::allInvariants)

  run reachExclusiveTakesNoNumberTest =
    L::init.then(L::doStartExclusive).then(L::doBodyExit)
      .expect(L::kind == "none" and L::n == 0 and L::allInvariants)

  run reachCancelFencedTest =
    L::init.then(L::doRequestStart).then(L::doStartTurn).then(L::doCancel(2)).then(L::doCancel(1))
      .expect(L::cancel and L::allInvariants)

  run reachBodyBoundForcesReleaseTest =
    L::init.then(L::doRequestStart).then(L::doStartTurn)
      .then(L::doCancel(0)).then(L::doCancel(0)).then(L::doCancel(0)).then(L::doCancel(0))
      .then(L::step)
      .expect(L::kind == "none" and L::allInvariants)
}
