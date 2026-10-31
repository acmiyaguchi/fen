// Deterministic witnesses (quint test) for the request-resolution proof model.
// w<issue>...Test: one counterexample per issue-design bug. reach...Test: the
// proposed protocol still answers, aborts, counts down and times out, falls
// back immediately when no resolver is present, and resolves on turn end and reload.
module witnesses {
  import requests(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
                  TIMEOUTS = false, RECHECK = false, VERSIONED = false, LOCAL = true,
                  RELOAD_RESOLVES = false) as I from "./model"
  import requests(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
                  TIMEOUTS = false, RECHECK = false, VERSIONED = false, LOCAL = false,
                  RELOAD_RESOLVES = false) as H from "./model"
  import requests(ANSWER_BY_ID = false, ACK_ANSWERS = false, END_RESOLVES = false,
                  TIMEOUTS = false, RECHECK = false, VERSIONED = false, LOCAL = true,
                  RELOAD_RESOLVES = false) as W from "./model"
  import requests(ANSWER_BY_ID = true, ACK_ANSWERS = true, END_RESOLVES = true,
                  TIMEOUTS = true, RECHECK = true, VERSIONED = true, LOCAL = false,
                  RELOAD_RESOLVES = true) as P from "./model"
  import requests(ANSWER_BY_ID = true, ACK_ANSWERS = true, END_RESOLVES = true,
                  TIMEOUTS = true, RECHECK = true, VERSIONED = true, LOCAL = true,
                  RELOAD_RESOLVES = true) as T from "./model"

  // #638: an idle-only command's picker is open, a turn starts under it, and
  // the answer runs the command's continuation while the turn runs (breaking
  // `resolutionInScope` and `refinesTasks`).
  run w638IdleCommandActsInTurnTest =
    I::init.then(I::cmdRequest).then(I::startTurn).then(I::answer(1, 0))
      .expect(not(I::resolutionInScope) and not(I::refinesTasks)
              and I::lastAction == "answerCmdWhileBusy" and I::running)

  // #398 (V2): a turn's request outlives the cancelled turn ...
  run w398TurnRequestOutlivesTurnTest =
    I::init.then(I::startTurn).then(I::toolRequest).then(I::cancel)
      .expect(not(I::noPendingForEndedTurn) and not(I::refinesTasks)
              and not(I::inheritsTasksInvariants)
              and I::rStatus.get(1) == "pending" and not(I::running))

  // ... and an answer to it is accepted for a turn that no longer exists.
  run w398AnswerForEndedTurnTest =
    I::init.then(I::startTurn).then(I::toolRequest).then(I::cancel).then(I::answer(1, 0))
      .expect(not(I::resolutionInScope) and I::lastAction == "answerForEndedTurn")

  // #398 (V5): a picker survives /reload and its pre-reload continuation runs.
  run w398StaleContinuationAfterReloadTest =
    I::init.then(I::cmdRequest).then(I::reload).then(I::answer(1, 0))
      .expect(not(I::noStaleContinuation) and I::lastAction == "answerCmd" and I::gen == 1)

  // #398 (V6): /model refreshes its choices; an answer made against the
  // first list is applied to the refreshed one.
  run w398AnswerAgainstStaleChoicesTest =
    I::init.then(I::cmdRequest).then(I::updateChoices(1)).then(I::answer(1, 0))
      .expect(not(I::answerMatchesShownChoices) and I::rVer.get(1) == 1)

  // #398 (V7): a late answer is ignored without an ack.
  run w398LateAnswerUnackedTest =
    I::init.then(I::cmdRequest).then(I::answer(1, 0)).then(I::cmdRequest).then(I::answer(1, 0))
      .expect(not(I::answersAcked) and I::lastAction == "answerLate")

  // #398 (V4): headless, the only remote disconnects while the turn is
  // parked on a request with no deadline.
  run w398HeadlessRequestNoResolverTest =
    H::init.then(H::connect).then(H::startTurn).then(H::toolRequest).then(H::disconnect)
      .expect(not(H::pendingHasPossibleResolver) and not(H::refinesTasks)
              and not(H::inheritsTasksInvariants) and H::parkedOn == 1)

  // #396 (V9): the reused web /select applies a stale answer to the active select.
  run w396BareIndexHitsOtherRequestTest =
    W::init.then(W::cmdRequest).then(W::answer(1, 0)).then(W::cmdRequest).then(W::answer(1, 0))
      .expect(not(W::answerHitsItsRequest) and W::rStatus.get(2) == "answered")

  // ---- reachability of the proposed protocol ----

  run reachTurnRequestAnsweredTest =
    P::init.then(P::connect).then(P::startTurn).then(P::toolRequest).then(P::answer(1, 0))
      .expect(P::lastAction == "answerResumesTurn" and P::parkedOn == -1 and P::running
              and P::inductiveInv)

  run reachCancelResolvesRequestTest =
    T::init.then(T::startTurn).then(T::toolRequest).then(T::cancel)
      .expect(T::rStatus.get(1) == "ended" and not(T::running) and T::inductiveInv)

  run reachTimeoutUnparksTest =
    P::init.then(P::connect).then(P::startTurn).then(P::toolRequest).then(P::disconnect)
      .then(P::tick(1)).then(P::timeout(1))
      .expect(P::rStatus.get(1) == "timeout" and P::parkedOn == -1 and P::rRem.get(1) == 0
              and P::inductiveInv)

  run reachNoResolverImmediateFallbackTest =
    P::init.then(P::startTurn).then(P::toolRequest)
      .expect(P::lastAction == "toolRequestFallback" and P::rStatus.get(1) == "timeout"
              and P::parkedOn == -1 and P::inductiveInv)

  run reachPickerAnsweredTest =
    T::init.then(T::cmdRequest).then(T::updateChoices(1)).then(T::answer(1, 1))
      .expect(T::lastAction == "answerCmd" and T::inductiveInv)

  run reachStaleChoicesRejectedTest =
    T::init.then(T::cmdRequest).then(T::updateChoices(1)).then(T::answer(1, 0))
      .expect(T::lastAction == "answerRejectedStaleChoices" and T::rStatus.get(1) == "pending"
              and T::inductiveInv)

  run reachPickerAbortedByTurnTest =
    T::init.then(T::cmdRequest).then(T::startTurn).then(T::answer(1, 0))
      .expect(T::lastAction == "answerAbortedBusy" and T::rStatus.get(1) == "aborted"
              and T::inductiveInv)

  run reachReloadResolvesPickerTest =
    T::init.then(T::cmdRequest).then(T::reload)
      .expect(T::rStatus.get(1) == "cancelled" and T::gen == 1 and T::inductiveInv)

  run reachLateAnswerAckedTest =
    T::init.then(T::cmdRequest).then(T::answer(1, 0)).then(T::answer(1, 0))
      .expect(T::lastAction == "answerLate" and T::ackOk and T::inductiveInv)
}
