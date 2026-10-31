// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows a case the `fixed` invariants rely on is reachable.
module witnesses {
  import tuiTurns(FIXES = Set()) as C from "./model"
  import tuiTurns(FIXES = Set("660", "661", "662", "663")) as F from "./model"

  // #660: on an idle btw tab, Ctrl-C would cancel the hidden main turn.
  run w660CtrlCCancelsHiddenMainTest =
    C::init.then(C::typeKey).then(C::enter).then(C::openSide)
      .expect(not(C::ctrlCActsOnShownTurn) and C::s.focus == "side"
              and C::ctrlCEffect(C::s) == "cancelMain")

  // #660: on a running subagent tab the busy row omits the hint, yet Ctrl-C
  // would cancel the main turn.
  run w660SubTabHintOmittedTest =
    C::init.then(C::typeKey).then(C::enter).then(C::subStart).then(C::focusMouse("sub"))
      .expect(not(C::busyHintTruthful) and C::busyHint(C::s) == "none"
              and C::ctrlCEffect(C::s) == "cancelMain")

  // #660: ... and the first press really does cancel it.
  run w660FirstPressCancelsMainTest =
    C::init.then(C::typeKey).then(C::enter).then(C::openSide).then(C::ctrlC)
      .expect(C::s.mainCancelReq and C::s.focus == "side" and C::lastAction == "cancelMain")

  // #661: a quit armed on main survives a mouse switch to another tab.
  run w661MouseSwitchKeepsArmTest =
    C::init.then(C::subStart).then(C::ctrlC).then(C::focusMouse("sub"))
      .expect(not(C::quitArmOnFocusedTab) and C::s.pendingQuit and C::s.armedOn == "main"
              and C::s.focus == "sub")

  // #662: a correction typed for turn 1, which errors, is injected into turn 2
  // after its prompt.
  run w662SteeringIntoNextTurnTest =
    C::init.then(C::typeKey).then(C::enter).then(C::typeKey).then(C::enter)
      .then(C::typeKey).then(C::mainFinish("error")).then(C::enter)
      .expect(not(C::steeringReachesItsTurn) and C::s.mainTurn == 2
              and C::s.delivered == [{ typedFor: 1, deliveredIn: 2 }])

  // #663: reopening /btw adopts the parked turn of the closed tab ...
  run w663ReopenAdoptsParkedTurnTest =
    C::init.then(C::openSide).then(C::typeKey).then(C::enter)
      .then(C::closeSide(false)).then(C::openSide)
      .expect(not(C::sideEntryOwned) and C::s.live.gen == 1 and C::s.sideGen == 2
              and C::s.live.discard)

  // ... and the old turn's reply lands in the new tab.
  run w663OldReplyInNewTabTest =
    C::init.then(C::openSide).then(C::typeKey).then(C::enter)
      .then(C::closeSide(false)).then(C::openSide).then(C::sideFinish)
      .expect(not(C::eventsInOwnTab)
              and C::s.transcripts.get("side") == [{ origin: "side", gen: 1 }])

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
