// Deterministic witnesses for the Ctrl-C ownership proof model.
module witnesses {
  import ctrlC(FIXES = Set()) as C from "./model"
  import ctrlC(FIXES = Set("660", "661")) as F from "./model"

  // #660: with main running, an idle btw tab's Ctrl-C cancels main ...
  run w660IdleSideCancelsMainTest =
    C::init.then(C::typeKey).then(C::submitMain).then(C::openSide)
      .expect(not(C::ctrlCActsOnShownTurn) and C::ctrlCEffect == "cancelMain")

  // ... and on a running subagent tab the busy row shows no hint for it.
  run w660SubTabHintOmittedTest =
    C::init.then(C::typeKey).then(C::submitMain).then(C::subStarts).then(C::focusTo("sub", true))
      .expect(not(C::busyHintTruthful) and C::busyHint == "none" and C::ctrlCEffect == "cancelMain")

  // #661: a tab click keeps the quit armed on main.
  run w661MouseSwitchKeepsArmTest =
    C::init.then(C::subStarts).then(C::ctrlCKey).then(C::focusTo("sub", true))
      .expect(not(C::quitArmOnFocusedTab) and C::pendingQuit and C::armedOn == "main")

  // ---- reachability of the fixed design ----

  run reachCancelThenForceQuitMainTest =
    F::init.then(F::typeKey).then(F::submitMain).then(F::ctrlCKey).then(F::ctrlCKey)
      .expect(F::quit and F::ctrlCInductive)

  run reachSideClearDraftWhileMainRunsTest =
    F::init.then(F::typeKey).then(F::submitMain).then(F::openSide).then(F::typeKey)
      .then(F::ctrlCKey)
      .expect(not(F::dSide) and F::mainBusy and not(F::cancelPressed) and F::ctrlCInductive)

  run reachSideCancelTest =
    F::init.then(F::openSide).then(F::typeKey).then(F::submitSide)
      .expect(F::ctrlCEffect == "cancelSide" and F::ctrlCInductive)

  run reachMouseDisarmTest =
    F::init.then(F::subStarts).then(F::ctrlCKey).then(F::focusTo("sub", true))
      .expect(not(F::pendingQuit) and F::focus == "sub" and F::ctrlCInductive)
}
