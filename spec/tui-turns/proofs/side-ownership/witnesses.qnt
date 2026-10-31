// Deterministic witnesses for the btw ownership proof model.
module witnesses {
  import sideOwnership(FIXES = Set("663")) as F from "./model"

  // ---- reachability of the fixed design ----

  run reachReopenWhileReapingTest =
    F::init.then(F::openSide).then(F::submitSide).then(F::closeSide(false)).then(F::openSide)
      .then(F::submitSide).then(F::reapEvent(false)).then(F::liveEvent(true))
      .expect(F::reaping and not(F::sideBusy) and F::ownershipInductive)

  run reachReapFinishesTest =
    F::init.then(F::openSide).then(F::submitSide).then(F::closeSide(false))
      .then(F::reapEvent(true))
      .expect(not(F::reaping) and F::ownershipInductive)

  run reachReloadCancelsLiveTest =
    F::init.then(F::openSide).then(F::submitSide).then(F::reload).then(F::liveEvent(true))
      .expect(not(F::livePresent) and not(F::sideBusy) and F::ownershipInductive)
}
