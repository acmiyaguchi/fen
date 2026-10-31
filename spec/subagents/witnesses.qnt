// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows the fixed design still reaches the case a fix guards.
module witnesses {
  import subagents(FIXES = Set()) as C from "./model"
  import subagents(FIXES = Set("645", "646", "647", "648", "649", "650")) as F from "./model"

  // #645: a parent with thinking on forwards its level; child accepts it.
  run reach645ThinkingLabelRejectedTest =
    F::initWith(true, false, false).then(F::launch(1, "blocking"))
      .expect(F::inheritedRoutingAccepted and F::runs.get(1).st == "running"
              and F::runs.get(1).alive)

  // #646: quit while a blocking run is live reaps its child.
  run reach646QuitOrphansBlockingTest =
    F::initWith(false, false, false).then(F::launch(1, "blocking")).then(F::quit)
      .expect(F::noOrphanAfterQuit and not(F::runs.get(1).alive))

  // #647: a background completion queued while idle is delivered before next answer.
  run reach647CompletionAfterAnswerTest =
    F::initWith(false, false, false).then(F::launch(1, "background")).then(F::naturalStop)
      .then(F::exit(1, "done")).then(F::userPrompt).then(F::naturalStop)
      .expect(F::completionBeforeNextAnswer and F::runs.get(1).told == 1)

  // #648: wait returns the result, and completion is delivered at most once.
  run reach648WaitThenFollowUpTwiceTest =
    F::initWith(false, false, false).then(F::launch(1, "background"))
      .then(F::exit(1, "done")).then(F::wait(1)).then(F::naturalStop)
      .expect(F::toldAtMostOnce and F::runs.get(1).told == 1)

  // #648: /cancel-all does not drop background completions.
  run reach648CancelAllDropsCompletionTest =
    F::initWith(false, false, false).then(F::launch(1, "background")).then(F::naturalStop)
      .then(F::exit(1, "done")).then(F::cancelAll)
      .expect(F::toldOrPending and F::runs.get(1).told == 0)

  // #649: a steer after the first answer keeps the tool budget enforced.
  run reach649SteerDisablesBudgetTest =
    F::initWith(false, false, false).then(F::launch(1, "blocking")).then(F::childAnswer(1))
      .then(F::steer(1)).then(F::childTool(1)).then(F::childTool(1)).then(F::pump(1))
      .expect(F::budgetEnforced and F::runs.get(1).tools == 2
              and F::runs.get(1).finSent)

  // #650: a background child cannot edit.
  run reach650BackgroundCanEditTest =
    F::initWith(false, false, false).then(F::launch(1, "background"))
      .expect(F::backgroundReadOnly and not(F::runs.get(1).canEdit))

  // #650: a parent with --web-search off disables it for the child.
  run reach650WebSearchNotInheritedTest =
    F::initWith(false, true, true).then(F::launch(1, "blocking"))
      .expect(F::noWiderNetwork and not(F::runs.get(1).web))

  // ---- reachability of the fixed design ----

  // A blocking run completes and its tool result is the one delivery.
  run reachBlockingCompleteTest =
    F::initWith(false, false, false).then(F::launch(1, "blocking")).then(F::childTool(1))
      .then(F::childAnswer(1)).then(F::exit(1, "done")).then(F::naturalStop)
      .expect(F::allInvariants and F::runs.get(1).told == 1 and F::phase == "idle")

  // A thinking parent launches a child that starts (level, not label), and
  // a background child is read-only without web search the parent disabled.
  run reachThinkingParentLaunchesTest =
    F::initWith(true, true, true).then(F::launch(1, "background"))
      .expect(F::allInvariants and F::runs.get(1).st == "running"
              and not(F::runs.get(1).canEdit) and not(F::runs.get(1).web))

  // The #647 schedule: the completion is delivered before the answer.
  run reachCompletionBeforeAnswerTest =
    F::initWith(false, false, false).then(F::launch(1, "background")).then(F::naturalStop)
      .then(F::exit(1, "done")).then(F::userPrompt).then(F::naturalStop)
      .expect(F::allInvariants and F::runs.get(1).told == 1 and F::queue == []
              and F::phase == "idle")

  // The #648 schedules: wait consumes the completion; /cancel-all keeps it.
  run reachWaitConsumesTest =
    F::initWith(false, false, false).then(F::launch(1, "background"))
      .then(F::exit(1, "done")).then(F::wait(1)).then(F::naturalStop)
      .expect(F::allInvariants and F::runs.get(1).told == 1 and F::queue == [])

  run reachCancelAllKeepsCompletionTest =
    F::initWith(false, false, false).then(F::launch(1, "background")).then(F::naturalStop)
      .then(F::exit(1, "done")).then(F::cancelAll)
      .expect(F::allInvariants and F::queue == [1])

  // The #649 schedule: the steered run still gets its finalize.
  run reachBudgetAfterSteerTest =
    F::initWith(false, false, false).then(F::launch(1, "blocking")).then(F::childAnswer(1))
      .then(F::steer(1)).then(F::childTool(1)).then(F::childTool(1)).then(F::pump(1))
      .expect(F::allInvariants and F::runs.get(1).finSent and F::runs.get(1).st == "finalizing")

  // The #646 schedule: quit reaps the blocking run.
  run reachQuitReapsBlockingTest =
    F::initWith(false, false, false).then(F::launch(1, "blocking"))
      .then(F::launch(2, "background")).then(F::quit)
      .expect(F::allInvariants and F::runs.get(1).st == "cancelled"
              and F::runs.get(2).st == "cancelled")

  // Turn cancel reaps a blocking run; /reload reaps and announces a
  // background one.
  run reachCancelAndReloadTest =
    F::initWith(false, false, false).then(F::launch(1, "blocking"))
      .then(F::launch(2, "background")).then(F::parentCancel).then(F::reload)
      .expect(F::allInvariants and F::runs.get(1).st == "cancelled"
              and F::runs.get(2).st == "cancelled" and F::queue == [2])
}
