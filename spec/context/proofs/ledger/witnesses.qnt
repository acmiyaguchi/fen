// Deterministic witnesses (quint test) for the usage-ledger proof model.
module witnesses {
  import ledger(FIXES = Set()) as C from "./model"
  import ledger(FIXES = Set("617", "618", "619", "620", "621")) as F from "./model"

  // #618: the run's usage is exact after compaction.
  run reach618RunUsageExactTest =
    F::initWith("anthropic", true).then(F::userTurn).then(F::request(1, 0, false))
      .then(F::compact(2))
      .expect(F::runUsageExact and F::allInvariants)

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
