// Reachability for the holder proof model, so its inductive proof is not
// vacuous: each lifecycle, fencing, return, and routing case actually happens.
module witnesses {
  import holderSpec as H from "./model"

  // Enter while idle queues the line; the idle tick starts turn 1 with it.
  run reachIdleOfferStartsTurnTest =
    H::init.then(H::doOffer(-1, 1, false)).then(H::doStartTurn)
      .expect(H::s.kind == "turn" and H::s.n == 1 and H::s.why.get(0) == "started"
              and H::s.whyN.get(0) == 1 and H::allInvariants)

  // A turn that crashes still releases; its unread steer line comes back, for turn 1.
  run reachCrashReleasesAndReturnsTest =
    H::init.then(H::doOffer(-1, 0, false)).then(H::doStartTurn)
      .then(H::doOffer(-1, 2, false)).then(H::doBodyExit(true))
      .expect(H::s.kind == "none" and not(H::body) and H::s.why.get(1) == "released"
              and H::s.whyN.get(1) == 1 and H::allInvariants)

  // A late offer that saw turn 1 is refused once turn 2 runs.
  run reachStaleOfferRefusedTest =
    H::init.then(H::doOffer(-1, 0, false)).then(H::doStartTurn).then(H::doBodyExit(false))
      .then(H::doOffer(-1, 0, false)).then(H::doStartTurn).then(H::doOffer(1, 1, false))
      .expect(H::s.n == 2 and H::s.why.get(2) == "refused" and H::s.steer == Set()
              and H::allInvariants)

  // "Start only if idle" (:turn 0) is refused while a turn runs.
  run reachStartIfIdleRefusedWhenBusyTest =
    H::init.then(H::doOffer(-1, 0, false)).then(H::doStartTurn).then(H::doOffer(0, 2, false))
      .expect(H::s.why.get(1) == "refused" and H::allInvariants)

  // A cancel for an old turn does nothing; one for the running turn arms it.
  run reachCancelFencedTest =
    H::init.then(H::doOffer(-1, 0, false)).then(H::doStartTurn).then(H::doCancel(2))
      .then(H::doCancel(1))
      .expect(H::s.cancel and H::allInvariants)

  // An offer behind /reload waits as a follow-up and is taken in a later turn.
  run reachOfferBehindExclusiveTest =
    H::init.then(H::doStartExclusive).then(H::doOffer(-1, 1, false)).then(H::doBodyExit(false))
      .then(H::doOffer(-1, 1, false)).then(H::doStartTurn).then(H::doTakeFollowUp)
      .expect(H::s.why.get(0) == "started" and H::s.why.get(1) == "taken"
              and H::s.n == 1 and H::allInvariants)

  // Steer lines are taken before follow-ups; repeated caller tags do not matter.
  run reachSteerBeforeFollowUpTest =
    H::init.then(H::doOffer(-1, 1, false)).then(H::doStartTurn)
      .then(H::doOffer(-1, 1, true)).then(H::doOffer(-1, 1, false))
      .then(H::doTakeSteer).then(H::doTakeFollowUp)
      .expect(H::s.why.get(2) == "taken" and H::s.why.get(1) == "taken" and H::orderOk
              and H::allInvariants)

  // :all drains every steer line at once, and the mode survives the turn's release.
  run reachDrainAllPersistsTest =
    H::init.then(H::doSetMode("steer", "all")).then(H::doOffer(-1, 0, false))
      .then(H::doStartTurn).then(H::doOffer(-1, 1, false)).then(H::doOffer(-1, 1, false))
      .then(H::doTakeSteer).then(H::doBodyExit(false))
      .expect(H::s.steer == Set() and H::s.why.get(1) == "taken" and H::s.why.get(2) == "taken"
              and H::steerMode == "all" and H::allInvariants)

  // A body that reaches the bound is forced to exit: the holder is released in time.
  run reachBodyBoundForcesReleaseTest =
    H::init.then(H::doOffer(-1, 0, false)).then(H::doStartTurn)
      .then(H::doCancel(0)).then(H::doCancel(0)).then(H::doCancel(0)).then(H::doCancel(0))
      .then(H::step)
      .expect(H::s.kind == "none" and H::heldFor == 0 and H::allInvariants)

  // A requested idle start that is overdue is taken by the forced tick.
  run reachIdleBoundForcesStartTest =
    H::init.then(H::doOffer(-1, 0, false)).then(H::doSetMode("steer", "one"))
      .then(H::doSetMode("steer", "one")).then(H::step)
      .expect(H::s.kind == "turn" and H::waitedFor == 0 and H::allInvariants)

  // By design (open question): a follow-up queued while idle without a start
  // request (an extension's :follow-up? offer) is not bounded; it waits for
  // the next turn however long that takes.
  run reachUnrequestedFollowUpWaitsTest =
    H::init.then(H::doOffer(-1, 0, true)).then(H::doSetMode("steer", "all"))
      .then(H::doSetMode("steer", "one")).then(H::doSetMode("steer", "all"))
      .expect(H::s.kind == "none" and H::s.followUp == Set(0) and not(H::s.start)
              and H::waitedFor == 0 and H::allInvariants)
}
