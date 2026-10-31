// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows that a behaviour the `fixed` invariants rely on is
// reachable, so no invariant passes because its case cannot happen.
module witnesses {
  import network(FIXES = Set()) as C from "./model"
  import network(FIXES = Set("629", "630")) as F from "./model"
  import network(FIXES = Set("630")) as F630 from "./model"

  // #629: a mid-stream retry keeps attempt 1's text in the open row, and
  // attempt 2's deltas append to it. One turn only, so it is not #630.
  run w629RetryKeepsSupersededTextTest =
    C::init.then(C::startTurn).then(C::streamToken)
      .then(C::attemptEnd("transient")).then(C::backoffDone)
      .then(C::streamToken).then(C::streamToken).then(C::attemptEnd("complete"))
      .expect(not(C::noSupersededText) and not(C::okReplyDisplayed)
              and C::rowsSingleTurn and C::noOpenRowWhenIdle)

  // #629 is independent of #630: closing rows on error/cancel does not
  // remove the superseded text.
  run w629NotFixedBy630Test =
    F630::init.then(F630::startTurn).then(F630::streamToken)
      .then(F630::attemptEnd("transient")).then(F630::backoffDone)
      .then(F630::streamToken).then(F630::streamToken).then(F630::attemptEnd("complete"))
      .expect(not(F630::okReplyDisplayed) and F630::rowsSingleTurn)

  // #630: a cancelled turn leaves its streaming row open.
  run w630CancelLeavesRowOpenTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::cancel)
      .expect(not(C::noOpenRowWhenIdle) and C::noSupersededText)

  // #630: the next turn's first delta joins the dead turn's row (error path).
  run w630NextTurnJoinsDeadRowTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::attemptEnd("permanent"))
      .then(C::startTurn).then(C::streamToken)
      .expect(not(C::rowsSingleTurn) and C::tui.rows.length() == 4)

  // ---- reachability of the fixed design ----

  // A turn completes and its reply is shown exactly as persisted.
  run reachCompleteTest =
    F::init.then(F::startTurn).then(F::streamToken).then(F::streamToken)
      .then(F::attemptEnd("complete"))
      .expect(F::phase == "idle" and F::history.length() == 1
              and F::history[0].outcome == "ok" and F::allInvariants)

  // A retried turn completes from attempt 2 and shows only attempt 2.
  run reachRetryThenCompleteTest =
    F::init.then(F::startTurn).then(F::streamToken)
      .then(F::attemptEnd("transient")).then(F::backoffDone)
      .then(F::streamToken).then(F::streamToken).then(F::attemptEnd("complete"))
      .expect(F::finalAttempt.get(1) == 2 and F::history[0].outcome == "ok"
              and F::allInvariants)

  // A cancel mid-stream, then a fresh turn that gets its own row.
  run reachCancelThenNextTurnTest =
    F::init.then(F::startTurn).then(F::streamToken).then(F::cancel)
      .then(F::startTurn).then(F::streamToken).then(F::streamToken)
      .then(F::attemptEnd("complete"))
      .expect(F::assistantRows(F::tui).length() == 2 and F::allInvariants)

  // A hosted tool cut off by a retry is cleared (#574), then the turn errors.
  run reachHostedRetryErrorTest =
    F::init.then(F::startTurn).then(F::hosted(true))
      .then(F::attemptEnd("transient")).then(F::backoffDone)
      .then(F::attemptEnd("transient"))
      .expect(F::phase == "idle" and F::history[0].outcome == "error"
              and not(F::tui.hosted) and F::allInvariants)

  // Cancel during backoff.
  run reachCancelInBackoffTest =
    F::init.then(F::startTurn).then(F::streamToken)
      .then(F::attemptEnd("transient")).then(F::cancel)
      .expect(F::history[0].outcome == "aborted" and F::allInvariants)
}
