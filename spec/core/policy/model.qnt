// The abstract policy and credential resolution machine (#675), checked on its own.
// Its invariants hold inductively (verify.tsv), so every concrete model
// that refines absNext inherits them.
module policySpec {
  import policyAbstract.* from "./abstract"

  pure val PARENT_TOOL_SETS: Set[Set[str]] = Set(
    Set("read", "edit"),
    ALL_TOOLS
  )
  pure val PARENT_THINKINGS: Set[str] = Set("off", "high")
  pure val PARENT_WEBS: Set[bool] = Set(true, false)
  pure val STORE_STATES: Set[(bool, bool)] = Set((false, false), (true, false), (true, true))
  pure val REQ_STATES: Set[(bool, bool)] = Set((false, false), (true, true))

  pure val ABS_STATES: Set[Abs] =
    tuples(PARENT_TOOL_SETS, PARENT_WEBS, PARENT_THINKINGS, STORE_STATES, REQ_STATES).map(t =>
      val pt = t._1
      val pw = t._2
      val pth = t._3
      val sp = t._4._1
      val sl = t._4._2
      val ra = t._5._1
      val rl = t._5._2
      Set(
        { parentTools: pt, parentWeb: pw, parentThinking: pth,
          mode: "none", childTools: Set(), childWeb: false, childThinking: "off",
          storePresent: sp, storeLive: sl, reqActive: ra, reqTokenLive: rl }
      )
      .union(
        PARENT_THINKINGS.map(cth =>
          { parentTools: pt, parentWeb: pw, parentThinking: pth,
            mode: "blocking", childTools: pt, childWeb: pw, childThinking: cth,
            storePresent: sp, storeLive: sl, reqActive: ra, reqTokenLive: rl }
        )
      )
      .union(
        PARENT_THINKINGS.map(cth =>
          { parentTools: pt, parentWeb: pw, parentThinking: pth,
            mode: "background", childTools: pt.exclude(MUTATING), childWeb: pw, childThinking: cth,
            storePresent: sp, storeLive: sl, reqActive: ra, reqTokenLive: rl }
        )
      )
    ).flatten()

  var a: Abs
  var prev: Abs

  action init = all { a' = absInit, prev' = absInit }

  action move(b: Abs): bool = all { a' = b, prev' = a }

  action doDeriveChild(m: str, overrideThinking: str): bool = all {
    m != "none",
    val ct = if (m == "background") a.parentTools.exclude(MUTATING) else a.parentTools
    val cth = if (overrideThinking != "" and LEVELS.contains(overrideThinking)) overrideThinking else a.parentThinking
    move({ ...a, mode: m, childTools: ct, childWeb: a.parentWeb, childThinking: cth }),
  }

  action doClearChild = all {
    a.mode != "none",
    move({ ...a, mode: "none", childTools: Set(), childWeb: false, childThinking: "off" }),
  }

  action doStoreLogin = all {
    move({ ...a, storePresent: true, storeLive: true }),
  }

  action doStoreLogout = all {
    not(a.reqActive),
    move({ ...a, storePresent: false, storeLive: false }),
  }

  action doStoreExpire = all {
    move({ ...a, storeLive: false }),
  }

  action doStoreRefresh = all {
    a.storePresent,
    move({ ...a, storeLive: true }),
  }

  action doStartRequest = all {
    not(a.reqActive),
    a.storePresent,
    a.storeLive,
    move({ ...a, reqActive: true, reqTokenLive: true }),
  }

  action doEndRequest = all {
    a.reqActive,
    move({ ...a, reqActive: false, reqTokenLive: false }),
  }

  action doStutter = all {
    a' = a,
    prev' = a,
  }

  action step = any {
    nondet m = Set("blocking", "background").oneOf()
    nondet ov = Set("", "off", "high").oneOf()
    doDeriveChild(m, ov),
    doClearChild,
    doStoreLogin,
    doStoreLogout,
    doStoreExpire,
    doStoreRefresh,
    doStartRequest,
    doEndRequest,
    doStutter,
  }

  // ---- properties ----

  val movesAreAbsSteps = absNext(prev, a)
  val toolsNarrowedInv = toolsNarrowed(a)
  val backgroundReadOnlyInv = backgroundReadOnly(a)
  val noWiderNetworkInv = noWiderNetwork(a)
  val validThinkingInv = validThinking(a)
  val noStaleRequestInv = noStaleRequest(a)
  val tokenLiveImpliesPresentInv = tokenLiveImpliesPresent(a)

  val inductiveInv = and {
    a.in(ABS_STATES),
    prev.in(ABS_STATES),
    absInv(a),
  }

  val allInvariants = and {
    movesAreAbsSteps,
    toolsNarrowedInv,
    backgroundReadOnlyInv,
    noWiderNetworkInv,
    validThinkingInv,
    noStaleRequestInv,
    tokenLiveImpliesPresentInv,
    inductiveInv,
  }
}
