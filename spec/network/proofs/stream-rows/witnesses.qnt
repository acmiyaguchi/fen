// Deterministic witnesses for the stream-rows proof model: the same two
// counterexamples as the integration model, and the fixed design's cases.
module witnesses {
  import streamrows(FIXES = Set()) as C from "./model"
  import streamrows(FIXES = Set("629", "630")) as F from "./model"

  // #629: a retried turn completes from attempt 2, but the row still starts
  // with attempt 1's text.
  run w629RetryKeepsSupersededTextTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::retry)
      .then(C::backoffDone).then(C::streamToken).then(C::streamToken)
      .then(C::complete)
      .expect(not(C::noSupersededText) and not(C::okReplyDisplayed) and C::rowsSingleTurn)

  // #630: a cancelled turn's row stays open and the next turn joins it.
  run w630NextTurnJoinsDeadRowTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::endFailed(true))
      .then(C::startTurn).then(C::streamToken)
      .expect(not(C::rowsSingleTurn) and C::noSupersededText)

  run w630ErrorLeavesRowOpenTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::endFailed(false))
      .expect(not(C::noOpenRowWhenIdle))

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
