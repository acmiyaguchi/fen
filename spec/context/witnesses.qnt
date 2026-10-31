// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows a behaviour of the fixed design is reachable.
module witnesses {
  import context(FIXES = Set()) as C from "./model"
  import context(FIXES = Set("617", "618", "619", "620", "621", "622", "623")) as F from "./model"

  // #617: the compact tool runs mid-loop after a --continue replay; the
  // summarized usage leaves /status and the summary call never enters it.
  run w617CompactionDropsSessionUsageTest =
    C::initWith("anthropic", true).then(C::userTurn).then(C::request(1)).then(C::compact)
      .expect(C::lastAction == "compactTool"
              and C::statusUsage.cacheWrite < C::add(C::replayedUsage, C::bus).cacheWrite
              and not(C::sessionUsageComplete))

  // #618: the run's usage is an index slice of the rewritten history.
  run w618RunUsageIndexSliceTest =
    C::initWith("anthropic", true).then(C::userTurn).then(C::request(1)).then(C::compact)
      .expect(C::wireResultUsage.input < C::bus.input and not(C::runUsageExact))

  // #619: headless JSON usage includes the replayed history, before any step.
  run w619JsonUsageIncludesReplayTest =
    C::initWith("anthropic", true)
      .expect(C::bus == C::ZERO and C::jsonUsage != C::ZERO and not(C::headlessUsageExact))

  // #620: after compaction the kept assistant's usage is still shown as exact.
  run w620StaleContextExactTest =
    C::initWith("anthropic", true).then(C::userTurn).then(C::request(1)).then(C::compact)
      .expect(C::contextInfo(C::msgs, C::epoch).exact and not(C::exactContextIsCurrent))

  // #621: an OpenAI cache read counts in total-tokens.
  run w621TotalIncludesCacheTest =
    C::initWith("openai", false).then(C::userTurn).then(C::request(0))
      .then(C::userTurn).then(C::request(1))
      .expect(C::msgs[C::msgs.length() - 1].usage.cacheRead > 0 and not(C::totalTokensConvention))

  // #622: a single-extension reload rotates the always-visible tools, so the
  // next request does not extend the previous one.
  run w622ReloadReordersToolsTest =
    C::initWith("anthropic", false).then(C::userTurn).then(C::request(0))
      .then(C::reloadExtension).then(C::userTurn).then(C::request(0))
      .expect(C::alwaysVis != [1, 2, 3] and not(C::prefixStableUnlessNamed))

  // #623: a parallel tool round moves the only message breakpoint past the
  // lookback window, so the previous request's entry is not read back.
  run w623MovingBreakpointMissesTest =
    C::initWith("anthropic", false).then(C::userTurn).then(C::request(2))
      .then(C::toolResultsAct(false)).then(C::request(1))
      .expect(C::prefixStableUnlessNamed and not(C::cacheReuseOnExtension))

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
