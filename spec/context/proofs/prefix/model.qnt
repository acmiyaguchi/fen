// Proof model: prompt-prefix stability and cache reuse (#622, #623).
//
//   packages/core/src/fen/core/agent.fnl         visible-tools (registry order,
//                                                then activated search tools)
//   packages/core/src/fen/core/extensions/register/tool.fnl
//                                                unregister-by-owner + append:
//                                                a single-extension reload moves
//                                                that owner's tools to the end
//   extensions/adapters/providers/anthropic/anthropic_messages.fnl
//                                                build-body: breakpoints on the
//                                                last tool, the system prompt and
//                                                the last message only
//
// Contract: request n+1 extends request n unless a named break point came
// between them; when it does extend it, everything request n cached is read
// back.
//
// Only what that needs, all scalars: a request's prefix is (tool order,
// activated search tools, system render, history generation, history
// blocks). Between named breaks history only grows, so "extends" is equality
// of the first four plus <= on the blocks, and a request reads back request
// n's entry exactly when one of its breakpoints is within the lookback window
// W of it (Anthropic) or always (OpenAI automatic prefix caching). Usage
// accounting is a separate proof model (../ledger).
module prefix {
  const FIXES: Set[str]

  pure val W = 4          // Anthropic lookback window, scaled (real: ~20 blocks)
  pure val MAX_BP = 4     // Anthropic cache_control breakpoint limit
  pure val MAXH = 14      // bound on history blocks
  pure val MAXG = 2       // bound on compactions
  pure val NSEARCH = 2    // search-gated tools

  var provider: str       // anthropic | openai
  var phase: str          // idle | req | tools
  var pendingK: int       // tool calls awaiting results
  // the next request's prefix
  var order: int          // rotation of the always-visible tools (registry order)
  var active: int         // activated search tools
  var sys: int            // system-prompt render
  var gen: int            // history generation (bumped by compaction)
  var hist: int           // history blocks
  // the previous request's prefix
  var havePrev: bool
  var pOrder: int
  var pActive: int
  var pSys: int
  var pGen: int
  var pHist: int
  var brokeNamed: bool    // a named break point since the previous request
  // ghosts
  var prefixOk: bool
  var reuseOk: bool
  var maxBp: int

  action keepPrev = all {
    havePrev' = havePrev, pOrder' = pOrder, pActive' = pActive, pSys' = pSys,
    pGen' = pGen, pHist' = pHist, prefixOk' = prefixOk, reuseOk' = reuseOk, maxBp' = maxBp,
  }

  action initWith(p: str): bool = all {
    provider' = p, phase' = "idle", pendingK' = 0,
    order' = 0, active' = 0, sys' = 0, gen' = 0, hist' = 0,
    havePrev' = false, pOrder' = 0, pActive' = 0, pSys' = 0, pGen' = 0, pHist' = 0,
    brokeNamed' = false, prefixOk' = true, reuseOk' = true, maxBp' = 0,
  }

  action init = {
    nondet p = Set("anthropic", "openai").oneOf()
    initWith(p)
  }

  action userTurn = all {
    phase == "idle", hist < MAXH,
    hist' = hist + 1, phase' = "req",
    provider' = provider, pendingK' = pendingK, order' = order, active' = active,
    sys' = sys, gen' = gen, brokeNamed' = brokeNamed, keepPrev,
  }

  // One provider round trip with k tool calls (k = 0: a text answer). The
  // assistant reply adds 1 + k blocks.
  action request(k: int): bool = all {
    phase == "req", hist + 1 + k <= MAXH,
    val ext = havePrev and order == pOrder and active == pActive and sys == pSys
              and gen == pGen and pHist <= hist
    val anth = provider == "anthropic"
    // fix #623: also re-mark the previous request's tail when it is still a
    // strict prefix, so its entry is an exact hit (4 of 4 breakpoints).
    val remark = FIXES.contains("623") and ext and pHist < hist
    // breakpoints: last tool, system, (previous tail), last message
    val bps = 3 + (if (remark) 1 else 0)
    val reads = not(anth) or remark or hist - pHist <= W
    all {
      prefixOk' = (not(havePrev) or brokeNamed or ext),
      reuseOk' = (not(ext) or brokeNamed or reads),
      maxBp' = if (anth and bps > maxBp) bps else maxBp,
      havePrev' = true, pOrder' = order, pActive' = active, pSys' = sys, pGen' = gen,
      pHist' = hist,
      brokeNamed' = false,
      hist' = hist + 1 + k,
      phase' = if (k == 0) "idle" else "tools", pendingK' = k,
      provider' = provider, order' = order, active' = active, sys' = sys, gen' = gen,
    }
  }

  // Tool results, one block each; with `search` one call was tool_search and
  // activated a search-gated tool (a named break: the tool list changes).
  action toolResults(search: bool): bool = all {
    phase == "tools", hist + pendingK <= MAXH,
    not(search) or active < NSEARCH,
    hist' = hist + pendingK, phase' = "req", pendingK' = 0,
    active' = if (search) active + 1 else active,
    brokeNamed' = (brokeNamed or search),
    provider' = provider, order' = order, sys' = sys, gen' = gen, keepPrev,
  }

  // Cancel at a yield: cancelled results for unreturned calls, then the
  // empty :aborted marker (never sent).
  action cancel = all {
    phase == "req" or phase == "tools", hist + pendingK <= MAXH,
    hist' = hist + pendingK, phase' = "idle", pendingK' = 0,
    provider' = provider, order' = order, active' = active, sys' = sys, gen' = gen,
    brokeNamed' = brokeNamed, keepPrev,
  }

  // Compaction (idle, or the compact tool mid-loop): a new history
  // generation of `after` blocks. A named break.
  action compact(after: int): bool = all {
    phase == "idle" or (phase == "tools" and pendingK == 1),
    gen < MAXG, after >= 1, after <= hist,
    gen' = gen + 1, hist' = after, brokeNamed' = true,
    provider' = provider, phase' = phase, pendingK' = pendingK, order' = order,
    active' = active, sys' = sys, keepPrev,
  }

  // `/extension reload NAME`: unregister-by-owner, then re-register; today
  // the owner's always-visible tools move to the end. Fix #622: a canonical
  // tool order that does not depend on registration order. Not a named
  // break: nothing the user asked for changed.
  action reloadExtension = all {
    phase == "idle",
    order' = if (FIXES.contains("622")) order else (order + 1) % 3,
    provider' = provider, phase' = phase, pendingK' = pendingK, active' = active,
    sys' = sys, gen' = gen, hist' = hist, brokeNamed' = brokeNamed, keepPrev,
  }

  // /reload, /thinking, /handoff re-render the system prompt: a named break.
  action rebuild = all {
    phase == "idle", sys < 2,
    sys' = sys + 1, brokeNamed' = true,
    provider' = provider, phase' = phase, pendingK' = pendingK, order' = order,
    active' = active, gen' = gen, hist' = hist, keepPrev,
  }

  // /model to the other provider: a new cache, a named break.
  action switchProvider = all {
    phase == "idle",
    provider' = if (provider == "anthropic") "openai" else "anthropic",
    brokeNamed' = true,
    phase' = phase, pendingK' = pendingK, order' = order, active' = active, sys' = sys,
    gen' = gen, hist' = hist, keepPrev,
  }

  action step = any {
    userTurn,
    nondet k = Set(0, 1, 2).oneOf()
    request(k),
    nondet s = Set(true, false).oneOf()
    toolResults(s),
    cancel,
    nondet a = 1.to(MAXH).oneOf()
    compact(a),
    reloadExtension,
    rebuild,
    switchProvider,
  }

  // ---- properties ----

  // Request n+1 extends request n except across a named break point.
  val prefixStableUnlessNamed = prefixOk

  // When it does extend it, everything request n cached is read back.
  val cacheReuseOnExtension = reuseOk

  val breakpointsWithinLimit = maxBp <= MAX_BP

  val allInvariants = prefixStableUnlessNamed and cacheReuseOnExtension and breakpointsWithinLimit

  // ---- inductive strengthening ----

  // Variable domains (Apalache reads these as the initial states of the
  // induction step).
  val domains = and {
    provider.in(Set("anthropic", "openai")),
    phase.in(Set("idle", "req", "tools")),
    pendingK.in(0.to(2)),
    order.in(0.to(2)),
    active.in(0.to(NSEARCH)),
    sys.in(0.to(2)),
    gen.in(0.to(MAXG)),
    hist.in(0.to(MAXH)),
    havePrev.in(Set(true, false)),
    pOrder.in(0.to(2)),
    pActive.in(0.to(NSEARCH)),
    pSys.in(0.to(2)),
    pGen.in(0.to(MAXG)),
    pHist.in(0.to(MAXH)),
    brokeNamed.in(Set(true, false)),
    prefixOk.in(Set(true, false)),
    reuseOk.in(Set(true, false)),
    maxBp.in(0.to(MAX_BP + 1)),
  }

  // Unless a named break came since, the next request's prefix extends the
  // previous request's: that is what makes prefixStableUnlessNamed
  // inductive (fix #622 alone suffices).
  val prefixInductive = and {
    domains,
    prefixStableUnlessNamed,
    (havePrev and not(brokeNamed)) implies
      (order == pOrder and active == pActive and sys == pSys and gen == pGen and pHist < hist),
  }

  // With the re-marked previous tail every extension reads it back, within
  // the breakpoint limit (needs #622 and #623).
  val cacheInductive = and { prefixInductive, cacheReuseOnExtension, breakpointsWithinLimit }
}

module current { import prefix(FIXES = Set("622", "623")).* }
module fix622 { import prefix(FIXES = Set("622", "623")).* }
module fix623 { import prefix(FIXES = Set("623")).* }
module fixed { import prefix(FIXES = Set("622", "623")).* }
