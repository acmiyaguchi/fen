// Deterministic witnesses for the stream-rows proof model: today's design
// carries the #629 and #630 fixes, so all reach...Tests show interesting
// states and former bug traces satisfy inductiveInv and allInvariants.
module witnesses {
  import streamrows(FIXES = Set("629", "630")) as C from "./model"
  import streamrows(FIXES = Set("629", "630")) as F from "./model"

  // #629: a retried turn completes from attempt 2, showing only attempt 2's text.
  run reach629RetryDropsAttemptTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::retry)
      .then(C::backoffDone).then(C::streamToken).then(C::streamToken)
      .then(C::complete)
      .expect(C::noSupersededText and C::okReplyDisplayed and C::rowsSingleTurn and C::allInvariants)

  // #630: a cancelled turn's row is closed so the next turn starts fresh.
  run reach630CancelNextTurnFreshTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::endFailed(true))
      .then(C::startTurn).then(C::streamToken)
      .expect(C::rowsSingleTurn and C::noSupersededText and C::allInvariants)

  // #630: an error closes the open row when idle.
  run reach630ErrorClosesRowTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::endFailed(false))
      .expect(C::noOpenRowWhenIdle and C::allInvariants)

  run reachRetryThenCompleteTest =
    F::init.then(F::startTurn).then(F::streamToken).then(F::retry)
      .then(F::backoffDone).then(F::streamToken).then(F::streamToken)
      .then(F::complete)
      .expect(F::phase == "idle" and F::attempt == 2 and F::inductiveInv)

  run reachCancelThenNextTurnTest =
    F::init.then(F::startTurn).then(F::streamToken).then(F::endFailed(true))
      .then(F::startTurn).then(F::streamToken).then(F::streamToken)
      .then(F::complete)
      .expect(F::turn == 2 and F::inductiveInv)

  run reachHostedRetryTest =
    F::init.then(F::startTurn).then(F::hostedEv(true)).then(F::retry)
      .expect(F::phase == "backoff" and not(F::hosted) and F::retrying and F::inductiveInv)
}
