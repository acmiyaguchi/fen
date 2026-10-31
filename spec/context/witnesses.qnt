// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows a behaviour of the fixed design is reachable.
module witnesses {
  import context(FIXES = Set()) as C from "./model"
  import context(FIXES = Set("617", "618", "619", "620", "621", "622", "623")) as F from "./model"

  // #618: wire `result` sums the run's live usage even after compaction.
  run reach618RunUsageExactTest =
    F::initWith("anthropic", true).then(F::userTurn).then(F::request(1)).then(F::compact)
      .expect(F::runUsageExact and F::allInvariants)

  // ---- reachability of the fixed design ----

  // A tool turn completes on Anthropic, reading the previous entry back.
  run reachToolTurnTest =
    F::initWith("anthropic", false).then(F::userTurn).then(F::request(2))
      .then(F::toolResultsAct(false)).then(F::request(0))
      .expect(F::phase == "idle" and F::msgs[F::msgs.length() - 1].usage.cacheRead > 0
              and F::allInvariants)

  // Compaction mid-loop after a replay keeps every total consistent.
  run reachCompactAfterReplayTest =
    F::initWith("anthropic", true).then(F::userTurn).then(F::request(1)).then(F::compact)
      .then(F::toolResultsAct(false)).then(F::request(0))
      .expect(F::lastAction == "requestText" and F::epoch > 0 and F::allInvariants)

  // A reload keeps the prefix, and the next request reads it back.
  run reachReloadKeepsPrefixTest =
    F::initWith("anthropic", false).then(F::userTurn).then(F::request(0))
      .then(F::reloadExtension).then(F::userTurn).then(F::request(0))
      .expect(F::msgs[F::msgs.length() - 1].usage.cacheRead > 0 and F::allInvariants)

  // OpenAI cache reads, cancel, a tool_search activation and a provider
  // switch (named breaks) all keep the invariants.
  run reachOpenaiSearchSwitchTest =
    F::initWith("openai", false).then(F::userTurn).then(F::request(1))
      .then(F::toolResultsAct(true)).then(F::request(0)).then(F::userTurn).then(F::cancel)
      .then(F::switchProvider).then(F::userTurn).then(F::request(0))
      .expect(F::provider == "anthropic" and F::active.size() == 1 and F::allInvariants)
}
