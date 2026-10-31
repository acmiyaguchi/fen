// Proof model: usage accounting as a fold over one ledger (#617-#621).
//
//   packages/util/src/fen/util/{tokens,turn_result}.fnl
//                                       usage-totals / sum-usage over
//                                       agent.messages; context-token-info
//   extensions/behaviors/companions/compact/init.fnl
//                                       finish-compact!: history becomes
//                                       [summary] ++ kept; the summary call's
//                                       usage goes out as :llm-end only
//   extensions/adapters/presenters/{rpc,json}/init.fnl
//                                       run / headless usage by index slice of
//                                       agent.messages
//   extensions/adapters/providers/openai/openai_completions.fnl
//                                       keeps the provider's total_tokens
//
// Target design (all fixes): one append-only ledger with an entry per
// provider call (turns and compaction alike, plus the replayed usage as a
// seed), and every view is a fold of the ledger from a marker: the session
// total from the start, the wire run total from the run's marker, the
// headless total from the invocation's marker. Compaction appends; nothing
// rewrites the ledger. Today's design keeps usage only on the assistant
// messages, so `msgU` (the usage on the messages in agent.messages, with the
// presenters' index markers into it) is today's accounting source, and
// compaction rewrites it.
//
// Only the accounting is here; prompt-prefix caching is ../prefix. A usage
// entry's token classes are folded into one count (`tok`), which is all the
// completeness properties compare; `total` is kept for #621.
module ledger {
  const FIXES: Set[str]

  pure val MAXLOG = 5     // bound on provider calls (ledger entries)
  pure val MAXCTX = 8     // bound on the context size after compaction

  // kind: replayed | turn | compaction. ctx: context size the call
  // reported; epoch: rewrites before it (fix #620 stamps every entry).
  type Entry = { kind: str, inp: int, cached: int, out: int, total: int, ctx: int, epoch: int }

  pure def tok(e: Entry): int = e.inp + e.cached + e.out

  // Tokens of the entries of l from index m on (a fold with an index
  // counter: no slicing with variable bounds).
  pure def sumFrom(l: List[Entry], m: int): int =
    l.foldl({ i: 0, s: 0 }, (a, e) => { i: a.i + 1, s: if (a.i >= m) a.s + tok(e) else a.s }).s

  // The last `n` entries of l.
  pure def lastN(l: List[Entry], n: int): List[Entry] =
    l.foldl({ i: 0, out: [] }, (a, e) =>
      { i: a.i + 1, out: if (a.i >= l.length() - n) a.out.append(e) else a.out }).out

  var provider: str         // anthropic | openai
  var phase: str            // idle | req | tools
  var pendingK: int
  var log: List[Entry]      // the ledger (fixes #617-#619)
  var msgU: List[Entry]     // usage on the assistant messages in agent.messages (today)
  var sinceUser: int        // assistant messages after the last user message
  var replayedTok: int      // tokens of the --continue history (ghost)
  var busTok: int           // tokens of every :llm-end this invocation (ghost == TUI cum-*)
  var runBusTok: int        // tokens of every :llm-end since the run started (ghost)
  var invMark: int          // ledger marker: this invocation's first entry
  var runMarkLog: int       // ledger marker: the run's first entry
  var runMarkMsg: int       // today's rpc marker: an index into agent.messages' usage
  var ctxNow: int           // the size the next request would send (ghost)
  var epoch: int            // history rewrites so far
  var lastIsAsst: bool      // no message appended since the latest provider reply

  action initWith(p: str, rep: bool): bool = {
    // one replayed exchange whose usage reported the then-current size 2
    val re = { kind: "replayed", inp: 0, cached: 0, out: 1, total: 1, ctx: 2, epoch: 0 }
    all {
      provider' = p, phase' = "idle", pendingK' = 0,
      log' = if (rep) [re] else [], msgU' = if (rep) [re] else [],
      sinceUser' = if (rep) 1 else 0,
      replayedTok' = if (rep) tok(re) else 0, busTok' = 0, runBusTok' = 0,
      invMark' = if (rep) 1 else 0, runMarkLog' = if (rep) 1 else 0,
      runMarkMsg' = if (rep) 1 else 0,
      ctxNow' = if (rep) 2 else 0, epoch' = 0, lastIsAsst' = rep,
    }
  }

  action init = {
    nondet p = Set("anthropic", "openai").oneOf()
    nondet rep = Set(true, false).oneOf()
    initWith(p, rep)
  }

  // A user prompt starts a run (turn-start / run-start markers).
  action userTurn = all {
    phase == "idle",
    phase' = "req", ctxNow' = ctxNow + 1, lastIsAsst' = false, sinceUser' = 0,
    runMarkLog' = log.length(), runMarkMsg' = msgU.length(), runBusTok' = 0,
    provider' = provider, pendingK' = pendingK, log' = log, msgU' = msgU,
    replayedTok' = replayedTok, busTok' = busTok, invMark' = invMark, epoch' = epoch,
  }

  // One provider call with k tool calls; `cached` prompt tokens read from
  // cache; `omit`: an OpenAI-compatible gateway left total_tokens out.
  action request(k: int, cached: int, omit: bool): bool = all {
    phase == "req", log.length() < MAXLOG, cached <= ctxNow,
    not(omit) or provider == "openai",
    val inp = ctxNow - cached
    val out = 1 + k
    val total =
      if (FIXES.contains("621")) inp + out            // normalized: input + output
      else if (provider == "anthropic") inp + out
      else if (omit) 0                                // gateway without total_tokens
      else inp + cached + out                         // provider total incl. cache reads
    val e = { kind: "turn", inp: inp, cached: cached, out: out, total: total,
              ctx: ctxNow + out, epoch: epoch }
    all {
      log' = log.append(e), msgU' = msgU.append(e),
      busTok' = busTok + tok(e), runBusTok' = runBusTok + tok(e),
      ctxNow' = ctxNow + out, lastIsAsst' = true, sinceUser' = sinceUser + 1,
      phase' = if (k == 0) "idle" else "tools", pendingK' = k,
      provider' = provider, replayedTok' = replayedTok, invMark' = invMark,
      runMarkLog' = runMarkLog, runMarkMsg' = runMarkMsg, epoch' = epoch,
    }
  }

  action toolResults = all {
    phase == "tools",
    phase' = "req", ctxNow' = ctxNow + pendingK, pendingK' = 0, lastIsAsst' = false,
    provider' = provider, log' = log, msgU' = msgU, sinceUser' = sinceUser,
    replayedTok' = replayedTok, busTok' = busTok, runBusTok' = runBusTok,
    invMark' = invMark, runMarkLog' = runMarkLog, runMarkMsg' = runMarkMsg, epoch' = epoch,
  }

  // Cancel at a yield: no usage for the in-flight call; cancelled results
  // and the :aborted marker are appended.
  action cancel = all {
    phase == "req" or phase == "tools",
    phase' = "idle", ctxNow' = ctxNow + pendingK, pendingK' = 0, lastIsAsst' = false,
    provider' = provider, log' = log, msgU' = msgU, sinceUser' = sinceUser,
    replayedTok' = replayedTok, busTok' = busTok, runBusTok' = runBusTok,
    invMark' = invMark, runMarkLog' = runMarkLog, runMarkMsg' = runMarkMsg, epoch' = epoch,
  }

  // Compaction (idle, or the compact tool mid-loop). The summary call is a
  // provider call: one ledger entry, one :llm-end. History becomes
  // [summary] ++ messages from the last user turn, `after` in size; today
  // that drops the usage of every summarized assistant message, and the
  // summary's usage is on no message. It does not append after the kept
  // assistant, so the last message is unchanged.
  action compact(after: int): bool = all {
    phase == "idle" or (phase == "tools" and pendingK == 1),
    log.length() < MAXLOG, after >= 1, after < ctxNow,
    val su = { kind: "compaction", inp: ctxNow, cached: 0, out: 1, total: ctxNow + 1,
               ctx: after, epoch: epoch + 1 }
    all {
      log' = log.append(su), msgU' = lastN(msgU, sinceUser),
      busTok' = busTok + tok(su), runBusTok' = runBusTok + tok(su),
      ctxNow' = after, epoch' = epoch + 1,
      provider' = provider, phase' = phase, pendingK' = pendingK, sinceUser' = sinceUser,
      replayedTok' = replayedTok, invMark' = invMark, runMarkLog' = runMarkLog,
      runMarkMsg' = runMarkMsg, lastIsAsst' = lastIsAsst,
    }
  }

  action step = any {
    userTurn,
    nondet k = Set(0, 1).oneOf()
    nondet c = Set(0, 1).oneOf()
    nondet o = Set(true, false).oneOf()
    request(k, c, o),
    toolResults,
    cancel,
    nondet a = 1.to(MAXCTX).oneOf()
    compact(a),
  }

  // ---- views ----

  // /status "reported usage".
  val statusTok = if (FIXES.contains("617")) sumFrom(log, 0) else sumFrom(msgU, 0)
  // rpc `result` usage for the current run.
  val runTok = if (FIXES.contains("618")) sumFrom(log, runMarkLog) else sumFrom(msgU, runMarkMsg)
  // headless JSON usage for this invocation.
  val jsonTok = if (FIXES.contains("619")) sumFrom(log, invMark) else sumFrom(msgU, 0)

  // tokens.context-token-info: the latest assistant usage is the baseline,
  // shown as exact when that assistant is the last message. Fix #620: only
  // usage reported since the latest rewrite counts (epoch stamp).
  val latest: Entry = msgU.foldl({ kind: "none", inp: 0, cached: 0, out: 0, total: 0, ctx: 0,
                                   epoch: -1 }, (_, e) => e)
  val shownExact =
    msgU.length() > 0 and lastIsAsst and (not(FIXES.contains("620")) or latest.epoch == epoch)

  // ---- properties ----

  // Session usage == replayed usage + every reported call.
  val sessionUsageComplete = statusTok == replayedTok + busTok

  // The run's usage is every call made since it started.
  val runUsageExact = runTok == runBusTok

  // Headless usage covers this invocation only.
  val headlessUsageExact = jsonTok == busTok

  // A size shown as exact is the size the next request would send.
  val exactContextIsCurrent = shownExact implies latest.ctx == ctxNow

  // total-tokens means input + output in every entry.
  val totalTokensConvention = log.foldl(true, (ok, e) => ok and e.total == e.inp + e.out)

  val allInvariants = and {
    sessionUsageComplete, runUsageExact, headlessUsageExact, exactContextIsCurrent,
    totalTokensConvention,
  }
}

module current { import ledger(FIXES = Set("617", "618", "619", "620", "621")).* }
module fixed { import ledger(FIXES = Set("617", "618", "619", "620", "621")).* }
module fix617 { import ledger(FIXES = Set("617")).* }
module fix618 { import ledger(FIXES = Set("618")).* }
module fix619 { import ledger(FIXES = Set("619")).* }
module fix620 { import ledger(FIXES = Set("620")).* }
module fix621 { import ledger(FIXES = Set("621")).* }
