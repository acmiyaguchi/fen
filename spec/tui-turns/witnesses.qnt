// Deterministic witnesses (quint test). Each reach...Test shows a case the
// `fixed` invariants rely on is reachable.
module witnesses {
  import tuiTurns(FIXES = Set("660", "661", "662", "663")) as F from "./model"

  // ---- reachability of the fixed design ----

  // Ctrl-C on the main tab still cancels the main turn.
  run reachMainCancelTest =
    F::init.then(F::typeKey).then(F::enter).then(F::ctrlC)
      .expect(F::s.mainCancelReq and F::s.cancelPressed and F::allInvariants)

  // On the idle btw tab Ctrl-C clears the side draft and leaves main alone.
  run reachSideClearDraftTest =
    F::init.then(F::typeKey).then(F::enter).then(F::openSide).then(F::typeKey).then(F::ctrlC)
      .expect(F::s.view == 0 and not(F::s.mainCancelReq) and F::s.mainBusy and F::allInvariants)

  // A running side turn is cancelled from its own tab.
  run reachSideCancelTest =
    F::init.then(F::openSide).then(F::typeKey).then(F::enter).then(F::ctrlC)
      .expect(F::s.live.cancel and F::allInvariants)

  // The two-press quit still works, and a mouse switch disarms it.
  run reachQuitAndMouseDisarmTest =
    F::init.then(F::subStart).then(F::ctrlC).then(F::focusMouse("sub"))
      .expect(not(F::s.pendingQuit) and F::allInvariants)

  run reachTwoPressQuitTest =
    F::init.then(F::ctrlC).then(F::ctrlC)
      .expect(F::s.quit and F::allInvariants)

  // Steering for a turn that errors is handed back; at a natural stop it is
  // delivered to its own turn.
  run reachSteeringHandedBackTest =
    F::init.then(F::typeKey).then(F::enter).then(F::typeKey).then(F::enter)
      .then(F::mainFinish("error"))
      .expect(F::s.returned == 1 and F::s.steerQ == List() and F::allInvariants)

  run reachSteeringDeliveredTest =
    F::init.then(F::typeKey).then(F::enter).then(F::typeKey).then(F::enter)
      .then(F::mainFinish("ok"))
      .expect(F::s.delivered == [{ typedFor: 1, deliveredIn: 1 }] and F::allInvariants)

  // Reopening /btw while the old turn is reaped gives a usable tab, and the
  // old turn's reply is dropped.
  run reachReopenWhileReapingTest =
    F::init.then(F::openSide).then(F::typeKey).then(F::enter)
      .then(F::closeSide(false)).then(F::openSide).then(F::typeKey).then(F::enter)
      .expect(F::s.sideBusy and F::s.live.gen == 2 and F::s.reaping == [1] and F::allInvariants)

  run reachSideTurnCompletesTest =
    F::init.then(F::openSide).then(F::typeKey).then(F::enter).then(F::sideEmit).then(F::sideFinish)
      .expect(not(F::s.sideBusy) and F::s.transcripts.get("side").length() == 3
              and F::allInvariants)
}
