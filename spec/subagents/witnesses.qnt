// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows the fixed design still reaches the case a fix guards.
module witnesses {
  import subagents(FIXES = Set()) as C from "./model"
  import subagents(FIXES = Set("645", "646", "647", "648", "649", "650")) as F from "./model"

  // #645: a parent with thinking on forwards its status label; the child
  // rejects --thinking at startup and the run fails before it starts.
  run w645ThinkingLabelRejectedTest =
    C::initWith(true, false, false).then(C::launch(1, "blocking"))
      .expect(not(C::inheritedRoutingAccepted) and C::runs.get(1).st == "failed"
              and not(C::runs.get(1).alive))

  // #646: quit while a blocking run is live leaves its child running.
  run w646QuitOrphansBlockingTest =
    C::initWith(false, false, false).then(C::launch(1, "blocking")).then(C::quit)
      .expect(not(C::noOrphanAfterQuit) and C::runs.get(1).alive
              and C::runs.get(1).mode == "blocking" and C::runs.get(1).st == "running")

  // #647: a background completion queued while idle reaches the model only
  // after it has answered the next prompt.
  run w647CompletionAfterAnswerTest =
    C::initWith(false, false, false).then(C::launch(1, "background")).then(C::naturalStop)
      .then(C::exit(1, "done")).then(C::userPrompt).then(C::naturalStop)
      .expect(not(C::completionBeforeNextAnswer) and C::runs.get(1).told == 1
              and C::phase == "busy")

  // #648: wait returns the result, and the queued follow-up delivers it again.
  run w648WaitThenFollowUpTwiceTest =
    C::initWith(false, false, false).then(C::launch(1, "background"))
      .then(C::exit(1, "done")).then(C::wait(1)).then(C::naturalStop)
      .expect(not(C::toldAtMostOnce) and C::runs.get(1).told == 2)

  // #648: /cancel-all drops the queued completion; nobody is told.
  run w648CancelAllDropsCompletionTest =
    C::initWith(false, false, false).then(C::launch(1, "background")).then(C::naturalStop)
      .then(C::exit(1, "done")).then(C::cancelAll)
      .expect(not(C::toldOrPending) and C::runs.get(1).told == 0 and C::queue == [])

  // #649: a steer after the first answer switches the tool budget off.
  run w649SteerDisablesBudgetTest =
    C::initWith(false, false, false).then(C::launch(1, "blocking")).then(C::childAnswer(1))
      .then(C::steer(1)).then(C::childTool(1)).then(C::childTool(1)).then(C::pump(1))
      .expect(not(C::budgetEnforced) and C::runs.get(1).tools == 2
              and not(C::runs.get(1).finSent) and C::runs.get(1).st == "running")

  // #650: a background child keeps edit authority.
  run w650BackgroundCanEditTest =
    C::initWith(false, false, false).then(C::launch(1, "background"))
      .expect(not(C::backgroundReadOnly) and C::runs.get(1).canEdit)

  // #650: a parent with --web-search off spawns a child with the settings
  // default (live).
  run w650WebSearchNotInheritedTest =
    C::initWith(false, true, true).then(C::launch(1, "blocking"))
      .expect(not(C::noWiderNetwork) and C::runs.get(1).web)

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
