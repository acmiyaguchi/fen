// Deterministic witnesses for the btw ownership proof model.
module witnesses {
  import sideOwnership(FIXES = Set()) as C from "./model"
  import sideOwnership(FIXES = Set("663")) as F from "./model"

  // #663: the reopened tab adopts the parked turn of the closed one ...
  run w663ReopenAdoptsParkedTurnTest =
    C::init.then(C::openSide).then(C::submitSide).then(C::closeSide(false)).then(C::openSide)
      .expect(not(C::sideEntryOwned) and C::liveGen == 1 and C::sideGen == 2)

  // ... and the old turn's final reply is delivered into the new tab.
  run w663OldReplyInNewTabTest =
    C::init.then(C::openSide).then(C::submitSide).then(C::closeSide(false)).then(C::openSide)
      .then(C::liveEvent(true))
      .expect(not(C::eventsInOwnTab))

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
