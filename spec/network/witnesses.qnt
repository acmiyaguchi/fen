// Deterministic witnesses (quint test). Today's code (`current`) carries the
// #629 and #630 fixes, so each reach...Test replays a trace and expects the
// invariants to hold; they show the behaviours the invariants rely on are
// reachable, so no invariant passes vacuously.
module witnesses {
  import network(FIXES = Set("629", "630")) as C from "./model"
  import network(FIXES = Set("629", "630")) as F from "./model"

  // #629: a mid-stream retry drops attempt 1's text from the open row, and
  // attempt 2 completes cleanly.
  run reach629RetryDropsAttemptTest =
    C::init.then(C::startTurn).then(C::streamToken)
      .then(C::attemptEnd("transient")).then(C::backoffDone)
      .then(C::streamToken).then(C::streamToken).then(C::attemptEnd("complete"))
      .expect(C::noSupersededText and C::okReplyDisplayed
              and C::rowsSingleTurn and C::noOpenRowWhenIdle and C::allInvariants)

  // #630: a cancelled turn closes its streaming row so nothing stays open.
  run reach630CancelClosesRowTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::cancel)
      .expect(C::noOpenRowWhenIdle and C::noSupersededText and C::allInvariants)

  // #630: after an error, the next turn starts a fresh row rather than joining
  // the dead turn's row.
  run reach630NextTurnStartsFreshTest =
    C::init.then(C::startTurn).then(C::streamToken).then(C::attemptEnd("permanent"))
      .then(C::startTurn).then(C::streamToken)
      .expect(C::rowsSingleTurn and C::tui.rows.length() == 5 and C::allInvariants)

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
