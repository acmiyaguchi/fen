// One input per issue: the outcome that breaks it in today's design (the
// reach6xx tests are the inputs that broke #633 and #634 before their fixes).
module witnesses {
  import outcome(FIXES = Set("633", "634")) as C from "./model"
  import outcome(FIXES = Set("634")) as F634 from "./model"
  import outcome(FIXES = Set("619", "632", "633", "634")) as F from "./model"

  run w619ReplayedUsageTest =
    C::initWith("ok", true, 1, "done")
      .expect(not(C::headlessUsageIsTurnUsage) and C::headlessExitMatchesStatus)

  run w632RpcQuotaExitsDoneTest =
    C::initWith("quota", false, 1, "none")
      .expect(not(C::rpcExitMatchesStatus) and C::rpcFinal == "blob"
              and C::headlessErrorDetailsMatch)

  run w632RpcCapToolTextTest =
    C::initWith("cap", false, 1, "none")
      .expect(not(C::rpcFinalTextMatches) and C::rpcFinal == "toolText")

  run reach633CancelClearsTextTest =
    C::initWith("cancelled", false, 2, "none")
      .expect(C::goalFinalTextMatches and C::goalResult == "none"
              and C::goalExitMatches)

  run w633ErrorKeepsPrevTextWith634Test =
    F634::initWith("error", false, 2, "none")
      .expect(not(F634::goalFinalTextMatches) and F634::goalStatus == "error")

  run reach634CapGoalErrorTest =
    C::initWith("cap", false, 1, "none")
      .expect(C::lifecycleStatus == "error" and C::goalStatus == "error"
              and C::goalExitMatches and C::lifecycleStatusMatchesOutcome)

  run reach634RefusedGoalErrorTest =
    C::initWith("refused", false, 2, "none")
      .expect(C::goalExitMatches)

  run reachOkDoneTest =
    F::initWith("ok", true, 2, "done")
      .expect(F::goalStatus == "done" and F::jsonUsage == 1 and F::allInvariants)

  run reachOkContinueRunningTest =
    F::initWith("ok", false, 1, "continue")
      .expect(not(F::goalTerminal) and F::allInvariants)

  run reachCapReachedTest =
    F::initWith("ok", false, 2, "continue")
      .expect(F::goalStatus == "cap-reached" and F::allInvariants)

  run reachQuotaFailsTest =
    F::initWith("quota", true, 2, "none")
      .expect(F::rpcExit == 1 and F::jsonDetails and F::goalResult == "none"
              and F::allInvariants)

  run reachCancelledTest =
    F::initWith("cancelled", false, 2, "none")
      .expect(F::goalStatus == "stopped" and F::allInvariants)
}
