// Model of fen's prompt-prefix caching and usage accounting across one
// session, as it works today.
//
// A request is abstracted as (visible tool list, system-prompt version,
// context message ids); every message has a block count that stands in for
// both its wire content blocks and its tokens. The provider is either
//   anthropic — explicit cache_control breakpoints (tools are rendered before
//               system, then messages); a breakpoint can read an earlier cache
//               entry only within W blocks of lookback; or
//   openai    — automatic prefix caching (no breakpoints, no lookback limit).
//
// Mirrors:
//   packages/core/src/fen/core/agent.fnl          visible-tools, build-context,
//                                                  step-loop, cancel pairing
//   extensions/adapters/providers/anthropic/anthropic_messages.fnl
//                                                  build-body: breakpoints on
//                                                  system, last tool, last msg
//   extensions/adapters/providers/openai/openai_{completions,responses_shared}.fnl
//                                                  usage->canonical / extract-usage
//   packages/util/src/fen/util/tokens.fnl         usage-totals, context-token-info
//   packages/util/src/fen/util/turn_result.fnl    sum-usage
//   extensions/behaviors/companions/compact/init.fnl
//                                                  finish-compact! (summary call
//                                                  usage on the bus only)
//   extensions/adapters/presenters/{rpc,json}/init.fnl
//                                                  run/turn usage by index slice
//   packages/core/src/fen/core/extensions/register/tool.fnl
//                                                  unregister-by-owner + append
//
// Ghost state records every usage report on the bus (`bus`); the TUI's
// cumulative counters are exactly that fold of :llm-end events. FIXES names
// the candidate fixes (by issue) so the same invariants can be checked against
// today's code, each fix alone, and all of them together.
module context {
  const FIXES: Set[str]

  pure val W = 4          // Anthropic lookback window, scaled (real: ~20 blocks)
  pure val MAX_BP = 4     // Anthropic cache_control breakpoint limit
  pure val MAXM = 12      // bound on history length
  pure val SEARCH = [10, 11]  // search-gated tools, in name order

  type Usage = { input: int, output: int, cacheRead: int, cacheWrite: int, total: int }
  pure val ZERO: Usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }

  pure def add(a: Usage, b: Usage): Usage =
    { input: a.input + b.input, output: a.output + b.output,
      cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite,
      total: a.total + b.total }

  // Token classes only; `total` is checked separately (totalTokensConvention).
  pure def sameTokens(a: Usage, b: Usage): bool =
    a.input == b.input and a.output == b.output and
    a.cacheRead == b.cacheRead and a.cacheWrite == b.cacheWrite

  // role: user | summary | assistant | tool | aborted
  type Msg = { id: int, role: str, blocks: int, usage: Usage }

  // A request prefix. sys < 0 marks a tools-only cache entry.
  type Key = { tools: List[int], sys: int, msgs: List[int] }

  pure def isPrefix(a: List[int], b: List[int]): bool =
    a.length() <= b.length() and a.indices().forall(i => a[i] == b[i])

  pure def extends(p: Key, r: Key): bool =
    p.tools == r.tools and p.sys == r.sys and isPrefix(p.msgs, r.msgs)

  pure def sizeOf(k: Key, bo: int -> int): int =
    k.tools.length() + (if (k.sys < 0) 0 else 1) +
    k.msgs.foldl(0, (s, id) => s + bo.get(id))

  pure def keyPrefix(e: Key, b: Key): bool =
    e.tools == b.tools and
    (e.sys < 0 or (e.sys == b.sys and isPrefix(e.msgs, b.msgs)))

  // agent.context-message?: the empty :aborted marker is never sent.
  pure def ctxIds(ms: List[Msg]): List[int] =
    ms.foldl([], (acc, m) => if (m.role == "aborted") acc else acc.append(m.id))

  pure def sumUsage(ms: List[Msg]): Usage =
    ms.foldl(ZERO, (acc, m) => if (m.role == "assistant") add(acc, m.usage) else acc)

  pure def suffix(ms: List[Msg], start: int): List[Msg] =
    if (start >= ms.length()) [] else ms.slice(start, ms.length())

  // build-body: system + last tool + last message; fix #623 also re-marks the
  // previous request's tail when it is still a prefix (4 of 4).
  pure def breakpoints(req: Key, prev: Key, havePrev: bool): List[Key] =
    val base = (if (req.tools.length() > 0) [{ tools: req.tools, sys: -1, msgs: [] }] else [])
                 .append({ ...req, msgs: [] })
    val withPrev =
      if (FIXES.contains("623") and havePrev and extends(prev, req) and prev.msgs.length() > 0
          and prev.msgs.length() < req.msgs.length())
        base.append(prev)
      else base
    if (req.msgs.length() > 0) withPrev.append(req) else withPrev

  // Longest cache entry a breakpoint can reach within the lookback window.
  pure def anthropicHit(cache: Set[Key], bps: List[Key], bo: int -> int): int =
    bps.foldl(0, (best, b) =>
      cache.fold(best, (acc, e) =>
        val se = sizeOf(e, bo)
        if (keyPrefix(e, b) and sizeOf(b, bo) - se <= W and se > acc) se else acc))

  pure def openaiHit(cache: Set[Key], req: Key, bo: int -> int): int =
    cache.fold(0, (acc, e) =>
      val se = sizeOf(e, bo)
      if (keyPrefix(e, req) and se > acc) se else acc)

  // tokens.context-token-info: the latest assistant with non-zero usage is
  // the baseline; exact when it is the last message. Fix #620 ignores
  // reports older than the last history rewrite (epoch).
  type Ctx = { exact: bool, tokens: int, idx: int }
  pure def contextInfo(ms: List[Msg], epoch: int): Ctx =
    ms.indices().fold({ exact: false, tokens: 0, idx: -1 }, (acc, i) =>
      val m = ms[i]
      val u = m.usage
      val n = u.input + u.output + u.cacheRead + u.cacheWrite
      if (m.role == "assistant" and n > 0 and i > acc.idx and (not(FIXES.contains("620")) or m.id > epoch))
        { exact: i == ms.length() - 1, tokens: n, idx: i }
      else acc)

  // ---- state ----
  var provider: str
  var alwaysVis: List[int]   // always-visible tools in registry order
  var active: Set[int]       // activated search tools
  var sys: int               // system-prompt render version
  var msgs: List[Msg]        // agent.messages
  var blocksOf: int -> int
  var nextId: int
  var phase: str             // idle | req | tools
  var pendingK: int
  var cache: Set[Key]
  var prevReq: Key
  var havePrev: bool
  var brokeNamed: bool       // an intended break point happened since the last request
  var epoch: int             // id of the latest compaction summary (fix #620)
  // ghost accounting
  var bus: Usage             // every :llm-end usage this process (== TUI cum-*)
  var ledger: Usage          // fixes #617-#619: session usage ledger, independent of msgs
  var replayed: int          // --continue messages before the run
  var replayedUsage: Usage
  var toolCalls: int
  var toolResults: int
  var maxBp: int
  var prefixOk: bool
  var reuseOk: bool
  var lastAction: str

  val reqKey: Key = {
    tools: alwaysVis.concat(SEARCH.select(t => active.contains(t))),
    sys: sys,
    msgs: ctxIds(msgs),
  }

  action unchangedCore = all {
    provider' = provider, alwaysVis' = alwaysVis, active' = active, sys' = sys,
    cache' = cache, prevReq' = prevReq, havePrev' = havePrev,
    replayed' = replayed, replayedUsage' = replayedUsage, maxBp' = maxBp,
  }

  // Startup on provider p, with or without a --continue replay (rep).
  action initWith(p: str, rep: bool): bool = {
    val ru = { input: 0, output: 1, cacheRead: 0, cacheWrite: 5, total: 1 }
    all {
      provider' = p,
      alwaysVis' = [1, 2, 3],
      active' = Set(),
      sys' = 0,
      msgs' = if (rep) [{ id: 1, role: "user", blocks: 1, usage: ZERO },
                        { id: 2, role: "assistant", blocks: 1, usage: ru }] else [],
      blocksOf' = Map(1 -> 1, 2 -> 1),
      nextId' = 3,
      phase' = "idle", pendingK' = 0,
      cache' = Set(),
      prevReq' = { tools: [], sys: 0, msgs: [] }, havePrev' = false,
      brokeNamed' = false, epoch' = 0,
      bus' = ZERO,
      ledger' = if (rep) ru else ZERO,
      replayed' = if (rep) 2 else 0,
      replayedUsage' = if (rep) ru else ZERO,
      toolCalls' = 0, toolResults' = 0, maxBp' = 0,
      prefixOk' = true, reuseOk' = true,
      lastAction' = "init",
    }
  }

  action init = {
    nondet p = Set("anthropic", "openai").oneOf()
    nondet rep = Set(true, false).oneOf()
    initWith(p, rep)
  }

  action userTurn = all {
    phase == "idle", msgs.length() < MAXM,
    msgs' = msgs.append({ id: nextId, role: "user", blocks: 1, usage: ZERO }),
    blocksOf' = blocksOf.put(nextId, 1), nextId' = nextId + 1,
    phase' = "req", pendingK' = 0,
    brokeNamed' = brokeNamed, epoch' = epoch, bus' = bus, ledger' = ledger,
    toolCalls' = toolCalls, toolResults' = toolResults,
    prefixOk' = prefixOk, reuseOk' = reuseOk,
    unchangedCore, lastAction' = "userTurn",
  }

  // One provider round trip (the last retry attempt; see spec/network).
  // k tool calls; k = 0 is a final text answer.
  action request(k: int): bool = all {
    phase == "req", msgs.length() < MAXM,
    val req = reqKey
    val anth = provider == "anthropic"
    val bps = if (anth) breakpoints(req, prevReq, havePrev) else [req]
    val hit = if (anth) anthropicHit(cache, bps, blocksOf) else openaiHit(cache, req, blocksOf)
    val reqSize = sizeOf(req, blocksOf)
    val out = 1 + k
    val u =
      if (anth) { input: 0, output: out, cacheRead: hit, cacheWrite: reqSize - hit, total: out }
      else {
        input: reqSize - hit, output: out, cacheRead: hit, cacheWrite: 0,
        // openai_completions/responses keep the provider's total_tokens,
        // which includes cached prompt tokens.
        total: if (FIXES.contains("621")) reqSize - hit + out else reqSize + out,
      }
    val ext = havePrev and extends(prevReq, req)
    all {
      msgs' = msgs.append({ id: nextId, role: "assistant", blocks: out, usage: u }),
      blocksOf' = blocksOf.put(nextId, out), nextId' = nextId + 1,
      phase' = if (k == 0) "idle" else "tools", pendingK' = k,
      cache' = cache.union(bps.foldl(Set(), (s, b) => s.union(Set(b)))),
      prevReq' = req, havePrev' = true,
      maxBp' = if (anth and bps.length() > maxBp) bps.length() else maxBp,
      prefixOk' = (not(havePrev) or brokeNamed or ext),
      reuseOk' = (not(ext) or brokeNamed or hit >= sizeOf(prevReq, blocksOf)),
      brokeNamed' = false,
      epoch' = epoch,
      bus' = add(bus, u), ledger' = add(ledger, u),
      toolCalls' = toolCalls + k, toolResults' = toolResults,
      provider' = provider, alwaysVis' = alwaysVis, active' = active, sys' = sys,
      replayed' = replayed, replayedUsage' = replayedUsage,
      lastAction' = if (k == 0) "requestText" else if (k == 1) "requestTool" else "requestParallelTools",
    }
  }

  pure def resultsOf(start: int, k: int): List[Msg] =
    if (k == 0) [] else if (k == 1) [{ id: start, role: "tool", blocks: 1, usage: ZERO }]
    else [{ id: start, role: "tool", blocks: 1, usage: ZERO },
          { id: start + 1, role: "tool", blocks: 1, usage: ZERO }]
  pure def putBlocks(bo: int -> int, start: int, k: int): int -> int =
    if (k == 0) bo else if (k == 1) bo.put(start, 1) else bo.put(start, 1).put(start + 1, 1)

  // Tool results for every call (normal, failed, refused under :tool-choice
  // :none — all pair one result per call). `search` = one call was
  // tool_search and activated a search-gated tool (an intended break).
  action toolResultsAct(search: bool): bool = all {
    phase == "tools",
    not(search) or active.size() < SEARCH.length(),
    msgs' = msgs.concat(resultsOf(nextId, pendingK)),
    blocksOf' = putBlocks(blocksOf, nextId, pendingK),
    nextId' = nextId + pendingK,
    phase' = "req", pendingK' = 0,
    active' = if (search) active.union(Set(SEARCH.select(t => not(active.contains(t)))[0])) else active,
    brokeNamed' = (brokeNamed or search),
    epoch' = epoch, bus' = bus, ledger' = ledger,
    toolCalls' = toolCalls, toolResults' = toolResults + pendingK,
    prefixOk' = prefixOk, reuseOk' = reuseOk,
    provider' = provider, alwaysVis' = alwaysVis, sys' = sys,
    cache' = cache, prevReq' = prevReq, havePrev' = havePrev,
    replayed' = replayed, replayedUsage' = replayedUsage, maxBp' = maxBp,
    lastAction' = if (search) "toolSearchResults" else "toolResults",
  }

  // Cancel at a yield: no usage is reported for an in-flight request; any
  // unreturned calls get cancelled results; an empty :aborted marker follows.
  action cancel = all {
    phase == "req" or phase == "tools",
    val res = resultsOf(nextId, pendingK)
    val ab = { id: nextId + pendingK, role: "aborted", blocks: 0, usage: ZERO }
    all {
      msgs' = msgs.concat(res).append(ab),
      blocksOf' = putBlocks(blocksOf, nextId, pendingK).put(nextId + pendingK, 0),
      nextId' = nextId + pendingK + 1,
      phase' = "idle", pendingK' = 0,
      toolResults' = toolResults + pendingK,
      brokeNamed' = brokeNamed, epoch' = epoch, bus' = bus, ledger' = ledger,
      toolCalls' = toolCalls, prefixOk' = prefixOk, reuseOk' = reuseOk,
      unchangedCore, lastAction' = "cancel",
    }
  }

  pure def lastUserIdx(ms: List[Msg]): int =
    ms.indices().fold(-1, (acc, i) =>
      if ((ms[i].role == "user" or ms[i].role == "summary") and i > acc) i else acc)

  // /compact, auto-compaction (idle) or the compact tool (mid tool loop):
  // the summary call's usage goes out as :llm-end only; history becomes
  // [summary] ++ messages from the last user boundary.
  action compact = all {
    phase == "idle" or (phase == "tools" and pendingK == 1),
    val cut = lastUserIdx(msgs)
    val summarized = if (cut > 0) msgs.slice(0, cut) else []
    val sIn = summarized.foldl(1, (s, m) => s + m.blocks)
    val su = { input: sIn, output: 1, cacheRead: 0, cacheWrite: 0, total: sIn + 1 }
    val summary = { id: nextId, role: "summary", blocks: 1, usage: ZERO }
    all {
      cut > 0,
      msgs' = [summary].concat(msgs.slice(cut, msgs.length())),
      blocksOf' = blocksOf.put(nextId, 1), nextId' = nextId + 1,
      phase' = phase, pendingK' = pendingK,
      brokeNamed' = true, epoch' = nextId,
      bus' = add(bus, su), ledger' = add(ledger, su),
      toolCalls' = toolCalls, toolResults' = toolResults,
      prefixOk' = prefixOk, reuseOk' = reuseOk,
      unchangedCore,
      lastAction' = if (phase == "idle") "compact" else "compactTool",
    }
  }

  // `/extension reload NAME` (or a scoped recovery reload): the loader runs
  // unregister-by-owner, then the extension registers again and its tools
  // are appended at the end of the registry. The agent is rebuilt.
  action reloadExtension = all {
    phase == "idle",
    alwaysVis' = if (FIXES.contains("622")) alwaysVis else alwaysVis.tail().append(alwaysVis.head()),
    msgs' = msgs, blocksOf' = blocksOf, nextId' = nextId, phase' = phase,
    pendingK' = pendingK, brokeNamed' = brokeNamed, epoch' = epoch,
    bus' = bus, ledger' = ledger, toolCalls' = toolCalls, toolResults' = toolResults,
    prefixOk' = prefixOk, reuseOk' = reuseOk,
    provider' = provider, active' = active, sys' = sys,
    cache' = cache, prevReq' = prevReq, havePrev' = havePrev,
    replayed' = replayed, replayedUsage' = replayedUsage, maxBp' = maxBp,
    lastAction' = "reloadExtension",
  }

  // /reload, /thinking, /handoff rebuild the agent and re-render the system
  // prompt (date, context files, skills): an intended break when it changes.
  action rebuild = all {
    phase == "idle", sys < 2,
    sys' = sys + 1, brokeNamed' = true,
    msgs' = msgs, blocksOf' = blocksOf, nextId' = nextId, phase' = phase,
    pendingK' = pendingK, epoch' = epoch,
    bus' = bus, ledger' = ledger, toolCalls' = toolCalls, toolResults' = toolResults,
    prefixOk' = prefixOk, reuseOk' = reuseOk,
    provider' = provider, alwaysVis' = alwaysVis, active' = active,
    cache' = cache, prevReq' = prevReq, havePrev' = havePrev,
    replayed' = replayed, replayedUsage' = replayedUsage, maxBp' = maxBp,
    lastAction' = "rebuild",
  }

  // /model to another provider: a new cache, an intended break.
  action switchProvider = all {
    phase == "idle",
    provider' = if (provider == "anthropic") "openai" else "anthropic",
    cache' = Set(), brokeNamed' = true,
    msgs' = msgs, blocksOf' = blocksOf, nextId' = nextId, phase' = phase,
    pendingK' = pendingK, epoch' = epoch,
    bus' = bus, ledger' = ledger, toolCalls' = toolCalls, toolResults' = toolResults,
    prefixOk' = prefixOk, reuseOk' = reuseOk,
    alwaysVis' = alwaysVis, active' = active, sys' = sys,
    prevReq' = prevReq, havePrev' = havePrev,
    replayed' = replayed, replayedUsage' = replayedUsage, maxBp' = maxBp,
    lastAction' = "switchProvider",
  }

  action step = any {
    userTurn,
    nondet k = Set(0, 1, 2).oneOf()
    request(k),
    nondet s = Set(true, false).oneOf()
    toolResultsAct(s),
    cancel,
    compact,
    reloadExtension,
    rebuild,
    switchProvider,
  }

  // ---- derived views ----
  // /status "reported usage" (tokens.usage-totals agent.messages).
  val statusUsage: Usage = if (FIXES.contains("617")) ledger else sumUsage(msgs)
  // rpc `result` usage: sum-usage over agent.messages from run-start-index.
  val wireResultUsage: Usage =
    if (FIXES.contains("618")) ledger else sumUsage(suffix(msgs, replayed))
  // json presenter usage: sum-usage over all agent.messages.
  val jsonUsage: Usage = if (FIXES.contains("619")) ledger else sumUsage(msgs)
  pure def minus(a: Usage, b: Usage): Usage =
    { input: a.input - b.input, output: a.output - b.output,
      cacheRead: a.cacheRead - b.cacheRead, cacheWrite: a.cacheWrite - b.cacheWrite,
      total: a.total - b.total }

  // ---- properties ----

  // Request n+1 extends request n except across a named break point.
  val prefixStableUnlessNamed = prefixOk

  // When it does extend it, everything request n cached is read back.
  val cacheReuseOnExtension = reuseOk

  val breakpointsWithinLimit = maxBp <= MAX_BP

  // Session usage (/status) == replayed usage + every reported call.
  val sessionUsageComplete = sameTokens(statusUsage, add(replayedUsage, bus))

  // Wire `result` usage sums the whole run (docs/wire.md).
  val runUsageExact =
    sameTokens(if (FIXES.contains("618")) minus(wireResultUsage, replayedUsage) else wireResultUsage, bus)

  // Headless JSON usage covers this invocation only.
  val headlessUsageExact =
    sameTokens(if (FIXES.contains("619")) minus(jsonUsage, replayedUsage) else jsonUsage, bus)

  // A context size shown as exact (provider-reported) is the real size of
  // what the next request would send.
  val exactContextIsCurrent =
    val c = contextInfo(msgs, epoch)
    c.exact implies c.tokens == sizeOf(reqKey, blocksOf)

  // usage.fnl: total-tokens conventionally excludes cache tokens.
  val totalTokensConvention =
    msgs.foldl(true, (ok, m) =>
      ok and (m.role != "assistant" or m.usage.total == m.usage.input + m.usage.output))

  // Every tool call has exactly one paired result once the turn is over.
  val toolPairing = phase == "idle" implies toolCalls == toolResults

  val allInvariants = and {
    prefixStableUnlessNamed, cacheReuseOnExtension, breakpointsWithinLimit,
    sessionUsageComplete, runUsageExact, headlessUsageExact,
    exactContextIsCurrent, totalTokensConvention, toolPairing,
  }
}

module current { import context(FIXES = Set("617", "618", "619", "620", "621", "622", "623")).* }
module fixed {
  import context(FIXES = Set("617", "618", "619", "620", "621", "622", "623")).*
}
// One fix at a time.
module fix617 { import context(FIXES = Set("617")).* }
module fix618 { import context(FIXES = Set("618")).* }
module fix619 { import context(FIXES = Set("619")).* }
module fix620 { import context(FIXES = Set("620")).* }
module fix621 { import context(FIXES = Set("621")).* }
module fix622 { import context(FIXES = Set("622")).* }
module fix623 { import context(FIXES = Set("623")).* }
