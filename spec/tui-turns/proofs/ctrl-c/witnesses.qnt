// Deterministic witnesses for the Ctrl-C ownership proof model.
module witnesses {
  import ctrlC(FIXES = Set("660", "661")) as F from "./model"

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
