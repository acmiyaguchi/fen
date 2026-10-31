// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for an issue `current` still has (or the
// named-fix instance that shows the issue is independent); each reach...Test
// shows that a case the invariants rely on is reachable, including the traces
// that once broke #631, #633 and #634 and now hold in `current`.
module witnesses {
  import presenters(FIXES = Set("631", "633", "634")) as C from "./model"
  import presenters(FIXES = Set("634")) as F634 from "./model"
  import presenters(FIXES = Set("619", "631", "632", "633", "634")) as F from "./model"

  // #619: after a --continue replay, the JSON usage counts the replayed turn.
  run w619ContinueUsageIncludesReplayTest =
    C::initWith(true).then(C::startStep).then(C::cancel)
      .expect(not(C::headlessUsageIsTurnUsage) and C::jsonUsage == 5
              and C::refUsage == 0 and C::headlessExitMatchesStatus)

  // #631: web drops attempt 1's text on a retry instead of joining attempt 2
  // onto it.
  run reach631WebRetryDropsAttemptTest =
    C::initWith(false).then(C::startStep).then(C::streamToken).then(C::retry)
      .then(C::streamToken).then(C::streamToken).then(C::endStop)
      .expect(C::webRowsSingleAttempt and C::webOkReplyShown
              and C::stdioLinesSingleAttempt and C::webRowsSingleStep)

  // #632: a provider error ends the rpc run with exit 0 and an "[error]"
  // final-text, while json/print exit 1.
  run w632RpcErrorExitsDoneTest =
    C::initWith(false).then(C::startStep).then(C::endError(true))
      .expect(not(C::rpcExitMatchesStatus) and not(C::rpcFinalTextMatches)
              and C::rpcFinal.blob and C::headlessExitMatchesStatus)

  // #632, cap path: the final-text is the tool-use assistant's text.
  run w632RpcCapExitsDoneTest =
    C::initWith(false).then(C::startStep).then(C::streamToken).then(C::streamToken)
      .then(C::endToolUse(false)).then(C::streamToken).then(C::streamToken)
      .then(C::endToolUse(false))
      .expect(C::stepEnd == "cap" and not(C::rpcExitMatchesStatus)
              and not(C::rpcFinalTextMatches))

  // #633: iteration 1 succeeds and continues; iteration 2 is cancelled; the
  // goal has no final text rather than iteration 1's.
  run reach633CancelClearsResultTest =
    C::initWith(false).then(C::startStep).then(C::streamToken).then(C::streamToken)
      .then(C::endStop).then(C::finishStep("continue"))
      .then(C::startStep).then(C::cancel).then(C::finishStep("continue"))
      .expect(C::goalFinalTextMatches and C::goal.status == "stopped"
              and not(C::goal.result.has) and C::goalExitMatches)

  // #633 is not fixed by #634's lifecycle fix: the error path keeps the
  // stale text too.
  run w633ErrorKeepsStaleResultWith634Test =
    F634::initWith(false).then(F634::startStep).then(F634::streamToken)
      .then(F634::streamToken).then(F634::endStop).then(F634::finishStep("continue"))
      .then(F634::startStep).then(F634::endError(true)).then(F634::finishStep("continue"))
      .expect(not(F634::goalFinalTextMatches) and F634::goal.status == "error")

  // #634: the safety cap ends the step, the lifecycle says error.
  run reach634CapLifecycleErrorTest =
    C::initWith(false).then(C::startStep).then(C::streamToken).then(C::streamToken)
      .then(C::endToolUse(false)).then(C::streamToken).then(C::streamToken)
      .then(C::endToolUse(false))
      .expect(C::stepEnd == "cap" and C::lifecycleStatus == "error"
              and C::lifecycleStatusMatchesOutcome)

  // #634: so the goal ends error (exit 1), not blocked (exit 2).
  run reach634CapGoalErrorTest =
    C::initWith(false).then(C::startStep).then(C::streamToken).then(C::streamToken)
      .then(C::endToolUse(false)).then(C::streamToken).then(C::streamToken)
      .then(C::endToolUse(false)).then(C::finishStep("continue"))
      .expect(C::goal.status == "error" and C::goalExitMatches)

  // ---- reachability of the fixed design ----

  run reachOkStepTest =
    F::initWith(true).then(F::startStep).then(F::streamToken).then(F::streamToken)
      .then(F::endStop)
      .expect(F::headlessStep and F::refExit == 0 and F::jsonFinal.has
              and F::jsonUsage == 1 and F::allInvariants)

  run reachRetryThenOkTest =
    F::initWith(false).then(F::startStep).then(F::streamToken).then(F::retry)
      .then(F::streamToken).then(F::streamToken).then(F::endStop)
      .expect(F::webOkReplyShown and F::allInvariants)

  run reachCapFailsTest =
    F::initWith(false).then(F::startStep).then(F::streamToken).then(F::streamToken)
      .then(F::endToolUse(false)).then(F::streamToken).then(F::streamToken)
      .then(F::endToolUse(false)).then(F::finishStep("continue"))
      .expect(F::goal.status == "error" and F::rpcExit == 1 and F::allInvariants)

  run reachRefusedFailsTest =
    F::initWith(false).then(F::startStep).then(F::streamToken).then(F::streamToken)
      .then(F::endToolUse(true)).then(F::streamToken).then(F::streamToken)
      .then(F::endToolUse(true))
      .expect(F::stepEnd == "refused" and F::jsonExit == 1 and F::allInvariants)

  run reachGoalTwoIterationsDoneTest =
    F::initWith(false).then(F::startStep).then(F::streamToken).then(F::streamToken)
      .then(F::endStop).then(F::finishStep("continue"))
      .then(F::startStep).then(F::streamToken).then(F::streamToken)
      .then(F::endStop).then(F::finishStep("done"))
      .expect(F::goal.status == "done" and F::goal.result.has and F::allInvariants)

  run reachGoalCancelledTest =
    F::initWith(false).then(F::startStep).then(F::streamToken).then(F::streamToken)
      .then(F::endStop).then(F::finishStep("continue"))
      .then(F::startStep).then(F::cancel).then(F::finishStep("continue"))
      .expect(F::goal.status == "stopped" and not(F::goal.result.has) and F::allInvariants)
}
