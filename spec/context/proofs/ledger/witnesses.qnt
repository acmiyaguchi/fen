// Deterministic witnesses (quint test) for the usage-ledger proof model.
module witnesses {
  import ledger(FIXES = Set()) as C from "./model"
  import ledger(FIXES = Set("617", "618", "619", "620", "621")) as F from "./model"

  // #617: the compact tool runs after a replay: the summarized usage and the
  // summary call itself are missing from the session total.
  run w617CompactionDropsSessionUsageTest =
    C::initWith("anthropic", true).then(C::userTurn).then(C::request(1, 0, false))
      .then(C::compact(2))
      .expect(C::msgU.length() == 1 and C::statusTok < C::replayedTok + C::busTok
              and not(C::sessionUsageComplete))

  // #618: the run's marker is an index into the rewritten message list.
  run w618RunUsageIndexSliceTest =
    C::initWith("anthropic", true).then(C::userTurn).then(C::request(1, 0, false))
      .then(C::compact(2))
      .expect(C::runMarkMsg >= C::msgU.length() and C::runTok == 0 and not(C::runUsageExact))

  // #619: headless usage includes the replayed history, before any step.
  run w619JsonUsageIncludesReplayTest =
    C::initWith("anthropic", true)
      .expect(C::busTok == 0 and C::jsonTok > 0 and not(C::headlessUsageExact))

  // #620: after compaction the kept assistant's size is still shown as exact.
  run w620StaleContextExactTest =
    C::initWith("anthropic", true).then(C::userTurn).then(C::request(1, 0, false))
      .then(C::compact(2))
      .expect(C::shownExact and C::latest.ctx > C::ctxNow and not(C::exactContextIsCurrent))

  // #621: an OpenAI cache read counts in total-tokens ...
  run w621TotalIncludesCacheTest =
    C::initWith("openai", false).then(C::userTurn).then(C::request(0, 1, false))
      .expect(C::log[0].total > C::log[0].inp + C::log[0].out and not(C::totalTokensConvention))
  // ... and a gateway that omits total_tokens records 0.
  run w621GatewayOmitsTotalTest =
    C::initWith("openai", false).then(C::userTurn).then(C::request(0, 0, true))
      .expect(C::log[0].total == 0 and not(C::totalTokensConvention))

  // ---- reachability of the fixed design ----

  // A compaction inside a run after a replay; the run then finishes and a
  // second run starts.
  run reachCompactInRunTest =
    F::initWith("anthropic", true).then(F::userTurn).then(F::request(1, 0, false))
      .then(F::compact(2)).then(F::toolResults).then(F::request(0, 1, false))
      .then(F::userTurn)
      .expect(F::log.length() == 4 and F::epoch == 1 and F::allInvariants)

  // After compaction the next reply is exact again.
  run reachExactAfterNewReplyTest =
    F::initWith("openai", false).then(F::userTurn).then(F::request(0, 0, false))
      .then(F::compact(1)).then(F::userTurn).then(F::request(0, 1, true))
      .expect(F::shownExact and F::allInvariants)

  // Cancel mid-tools reports no usage and keeps every total.
  run reachCancelTest =
    F::initWith("anthropic", false).then(F::userTurn).then(F::request(1, 0, false))
      .then(F::cancel)
      .expect(F::phase == "idle" and not(F::shownExact) and F::allInvariants)
}
