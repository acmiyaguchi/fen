// Deterministic witnesses (quint test) for the prefix-cache proof model.
module witnesses {
  import prefix(FIXES = Set()) as C from "./model"
  import prefix(FIXES = Set("622")) as F622 from "./model"
  import prefix(FIXES = Set("623")) as F623 from "./model"
  import prefix(FIXES = Set("622", "623")) as F from "./model"

  run w622SurvivesFix623Test =
    F623::initWith("anthropic").then(F623::userTurn).then(F623::request(0))
      .then(F623::reloadExtension).then(F623::userTurn).then(F623::request(0))
      .expect(not(F623::prefixStableUnlessNamed))

  // ---- reachability of the fixed design ----

  // A parallel tool round is read back through the re-marked tail, with all
  // four breakpoints in use.
  run reachParallelRoundReusedTest =
    F::initWith("anthropic").then(F::userTurn).then(F::request(2))
      .then(F::toolResults(false)).then(F::request(1))
      .expect(F::maxBp == 4 and F::cacheReuseOnExtension and F::cacheInductive)

  // A reload keeps the prefix.
  run reachReloadKeepsPrefixTest =
    F::initWith("anthropic").then(F::userTurn).then(F::request(0))
      .then(F::reloadExtension).then(F::userTurn).then(F::request(0))
      .expect(F::havePrev and F::order == 0 and F::cacheInductive)

  // Named breaks (tool_search, compaction, rebuild, provider switch) and a
  // cancel are all reachable and keep the invariants.
  run reachNamedBreaksTest =
    F::initWith("openai").then(F::userTurn).then(F::request(1)).then(F::toolResults(true))
      .then(F::request(1)).then(F::compact(2)).then(F::toolResults(false)).then(F::request(0))
      .then(F::rebuild).then(F::switchProvider).then(F::userTurn).then(F::cancel)
      .expect(F::active == 1 and F::gen == 1 and F::sys == 1 and F::provider == "anthropic"
              and F::cacheInductive)
}
