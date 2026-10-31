// Deterministic witnesses for the one-run lifecycle proof model.
module witnesses {
  import lifecycle(FIXES = Set()) as C from "./model"
  import lifecycle(FIXES = Set("646", "647", "648", "649")) as F from "./model"

  // #646: quit leaves a live blocking child.
  run w646QuitOrphansBlockingTest =
    C::init.then(C::launch("blocking")).then(C::quit)
      .expect(not(C::noOrphanAfterQuit) and C::alive and C::mode == "blocking")

  // #647: the completion queued while idle is injected after the answer.
  run w647CompletionAfterAnswerTest =
    C::init.then(C::launch("background")).then(C::naturalStop).then(C::exit)
      .then(C::userPrompt).then(C::naturalStop)
      .expect(not(C::completionBeforeNextAnswer) and C::told == 1 and C::phase == "busy")

  // #648: wait, then the queued follow-up: two deliveries.
  run w648WaitThenFollowUpTwiceTest =
    C::init.then(C::launch("background")).then(C::exit).then(C::wait).then(C::naturalStop)
      .expect(not(C::toldAtMostOnce) and C::told == 2)

  // #648: /cancel-all drops the undelivered completion.
  run w648CancelAllDropsCompletionTest =
    C::init.then(C::launch("background")).then(C::naturalStop).then(C::exit)
      .then(C::cancelAll)
      .expect(not(C::toldOrPending) and C::told == 0 and not(C::queued))

  // #649: steer after the answer, two tool calls, no finalize.
  run w649SteerDisablesBudgetTest =
    C::init.then(C::launch("blocking")).then(C::childAnswer).then(C::steer)
      .then(C::childTool).then(C::childTool).then(C::pump)
      .expect(not(C::budgetEnforced) and C::tools == 2 and not(C::finSent))

  // ---- reachability of the fixed design ----

  run reachBlockingCompleteTest =
    F::init.then(F::launch("blocking")).then(F::childTool).then(F::childAnswer)
      .then(F::exit).then(F::naturalStop)
      .expect(F::fixedInductive and F::told == 1 and F::phase == "idle" and F::st == "done")

  run reachCompletionBeforeAnswerTest =
    F::init.then(F::launch("background")).then(F::naturalStop).then(F::exit)
      .then(F::userPrompt).then(F::naturalStop)
      .expect(F::fixedInductive and F::told == 1 and not(F::queued) and F::phase == "idle")

  run reachWaitConsumesTest =
    F::init.then(F::launch("background")).then(F::exit).then(F::wait).then(F::naturalStop)
      .expect(F::fixedInductive and F::told == 1 and F::phase == "idle")

  run reachCancelAllKeepsCompletionTest =
    F::init.then(F::launch("background")).then(F::naturalStop).then(F::exit)
      .then(F::cancelAll).then(F::userPrompt).then(F::naturalStop)
      .expect(F::fixedInductive and F::told == 1)

  run reachBudgetAfterSteerTest =
    F::init.then(F::launch("blocking")).then(F::childAnswer).then(F::steer)
      .then(F::childTool).then(F::childTool).then(F::pump)
      .expect(F::fixedInductive and F::finSent and F::st == "finalizing")

  run reachQuitReapsBlockingTest =
    F::init.then(F::launch("blocking")).then(F::quit)
      .expect(F::fixedInductive and F::st == "cancelled" and F::told == 1)

  run reachReloadAnnouncesTest =
    F::init.then(F::launch("background")).then(F::naturalStop).then(F::reload)
      .then(F::userPrompt).then(F::naturalStop)
      .expect(F::fixedInductive and F::st == "cancelled" and F::told == 1)

  run reachTurnCancelTest =
    F::init.then(F::launch("blocking")).then(F::parentCancel)
      .expect(F::fixedInductive and F::st == "cancelled" and F::phase == "idle")
}
