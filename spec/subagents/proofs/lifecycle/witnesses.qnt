// Deterministic witnesses for the one-run lifecycle proof model.
module witnesses {
  import lifecycle(FIXES = Set()) as C from "./model"
  import lifecycle(FIXES = Set("646", "647", "648", "649")) as F from "./model"

  // #646: quit reaps live blocking child.
  run reach646QuitOrphansBlockingTest =
    F::init.then(F::launch("blocking")).then(F::quit)
      .expect(F::noOrphanAfterQuit and not(F::alive))

  // #647: the completion queued while idle is injected before the answer.
  run reach647CompletionAfterAnswerTest =
    F::init.then(F::launch("background")).then(F::naturalStop).then(F::exit)
      .then(F::userPrompt).then(F::naturalStop)
      .expect(F::completionBeforeNextAnswer and F::told == 1)

  // #648: wait, then follow-up: delivered at most once.
  run reach648WaitThenFollowUpTwiceTest =
    F::init.then(F::launch("background")).then(F::exit).then(F::wait).then(F::naturalStop)
      .expect(F::toldAtMostOnce and F::told == 1)

  // #648: /cancel-all keeps the undelivered completion.
  run reach648CancelAllDropsCompletionTest =
    F::init.then(F::launch("background")).then(F::naturalStop).then(F::exit)
      .then(F::cancelAll)
      .expect(F::toldOrPending and F::allInvariants)

  // #649: steer after the answer keeps the budget enforced.
  run reach649SteerDisablesBudgetTest =
    F::init.then(F::launch("blocking")).then(F::childAnswer).then(F::steer)
      .then(F::childTool).then(F::childTool).then(F::pump)
      .expect(F::budgetEnforced and F::tools == 2 and F::finSent)

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
