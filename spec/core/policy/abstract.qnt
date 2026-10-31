// Abstract specification of policy derivation and credential resolution (#675):
// child authority derived from parent, and per-request credential resolution.
//
// 1. Policy derivation & narrowing:
//    - Child tools are strictly narrowed by the parent's tools.
//    - Background jobs strip mutating tools (read-only execution).
//    - Web search is never wider than parent settings.
//    - Thinking levels are derived from the parent's materialized level
//      unless explicitly overridden by the caller.
//
// 2. Per-request credential resolution:
//    - Credentials are resolved from the auth store per request, never pinned
//      at construction.
//    - Provider requests go out only with fresh, live credentials.
//
// Pure definitions only, so concrete models can import them.
module policyAbstract {
  pure val ALL_TOOLS: Set[str] = Set("read", "edit", "bash")
  pure val MUTATING: Set[str] = Set("edit", "bash")
  pure val LEVELS: Set[str] = Set("off", "low", "high")

  type Abs = {
    // Parent authority
    parentTools: Set[str],
    parentWeb: bool,
    parentThinking: str,

    // Derived execution / child policy
    mode: str,                 // "none" | "blocking" | "background"
    childTools: Set[str],
    childWeb: bool,
    childThinking: str,

    // Per-request credentials from store
    storePresent: bool,
    storeLive: bool,
    reqActive: bool,
    reqTokenLive: bool,
  }

  pure val absInit: Abs = {
    parentTools: ALL_TOOLS,
    parentWeb: true,
    parentThinking: "high",
    mode: "none",
    childTools: Set(),
    childWeb: false,
    childThinking: "off",
    storePresent: true,
    storeLive: true,
    reqActive: false,
    reqTokenLive: false,
  }

  // Derive child policy from parent authority.
  pure def deriveChild(a: Abs, b: Abs): bool = and {
    b.mode != "none",
    b.parentTools == a.parentTools,
    b.parentWeb == a.parentWeb,
    b.parentThinking == a.parentThinking,
    b.childTools == (if (b.mode == "background") a.parentTools.exclude(MUTATING) else a.parentTools),
    b.childWeb == a.parentWeb,
    LEVELS.contains(b.childThinking),
    b.storePresent == a.storePresent,
    b.storeLive == a.storeLive,
    b.reqActive == a.reqActive,
    b.reqTokenLive == a.reqTokenLive,
  }

  // Clear child policy when child is idle / done.
  pure def clearChild(a: Abs, b: Abs): bool = and {
    a.mode != "none",
    b.mode == "none",
    b.childTools == Set(),
    b.childWeb == false,
    b.childThinking == "off",
    b.parentTools == a.parentTools,
    b.parentWeb == a.parentWeb,
    b.parentThinking == a.parentThinking,
    b.storePresent == a.storePresent,
    b.storeLive == a.storeLive,
    b.reqActive == a.reqActive,
    b.reqTokenLive == a.reqTokenLive,
  }

  // Configure parent authority (when no child is active).
  pure def configureParent(a: Abs, b: Abs, tools: Set[str], web: bool, thinking: str): bool = and {
    a.mode == "none",
    tools.subseteq(ALL_TOOLS),
    LEVELS.contains(thinking),
    b.mode == "none",
    b.childTools == a.childTools,
    b.childWeb == a.childWeb,
    b.childThinking == a.childThinking,
    b.parentTools == tools,
    b.parentWeb == web,
    b.parentThinking == thinking,
    b.storePresent == a.storePresent,
    b.storeLive == a.storeLive,
    b.reqActive == a.reqActive,
    b.reqTokenLive == a.reqTokenLive,
  }

  // Store credentials actions.
  pure def storeLogin(a: Abs, b: Abs): bool = and {
    b.storePresent,
    b.storeLive,
    b.parentTools == a.parentTools,
    b.parentWeb == a.parentWeb,
    b.parentThinking == a.parentThinking,
    b.mode == a.mode,
    b.childTools == a.childTools,
    b.childWeb == a.childWeb,
    b.childThinking == a.childThinking,
    b.reqActive == a.reqActive,
    b.reqTokenLive == a.reqTokenLive,
  }

  pure def storeLogout(a: Abs, b: Abs): bool = and {
    not(a.reqActive),
    not(b.storePresent),
    not(b.storeLive),
    b.parentTools == a.parentTools,
    b.parentWeb == a.parentWeb,
    b.parentThinking == a.parentThinking,
    b.mode == a.mode,
    b.childTools == a.childTools,
    b.childWeb == a.childWeb,
    b.childThinking == a.childThinking,
    not(b.reqActive),
    not(b.reqTokenLive),
  }

  pure def storeExpire(a: Abs, b: Abs): bool = and {
    b.storePresent == a.storePresent,
    not(b.storeLive),
    b.parentTools == a.parentTools,
    b.parentWeb == a.parentWeb,
    b.parentThinking == a.parentThinking,
    b.mode == a.mode,
    b.childTools == a.childTools,
    b.childWeb == a.childWeb,
    b.childThinking == a.childThinking,
    b.reqActive == a.reqActive,
    b.reqTokenLive == a.reqTokenLive,
  }

  pure def storeRefresh(a: Abs, b: Abs): bool = and {
    a.storePresent,
    b.storePresent,
    b.storeLive,
    b.parentTools == a.parentTools,
    b.parentWeb == a.parentWeb,
    b.parentThinking == a.parentThinking,
    b.mode == a.mode,
    b.childTools == a.childTools,
    b.childWeb == a.childWeb,
    b.childThinking == a.childThinking,
    b.reqActive == a.reqActive,
    b.reqTokenLive == a.reqTokenLive,
  }

  // Per-request credential resolution.
  pure def startRequest(a: Abs, b: Abs): bool = and {
    not(a.reqActive),
    a.storePresent,
    a.storeLive,
    b.reqActive,
    b.reqTokenLive,
    b.storePresent == a.storePresent,
    b.storeLive == a.storeLive,
    b.parentTools == a.parentTools,
    b.parentWeb == a.parentWeb,
    b.parentThinking == a.parentThinking,
    b.mode == a.mode,
    b.childTools == a.childTools,
    b.childWeb == a.childWeb,
    b.childThinking == a.childThinking,
  }

  pure def endRequest(a: Abs, b: Abs): bool = and {
    a.reqActive,
    not(b.reqActive),
    not(b.reqTokenLive),
    b.storePresent == a.storePresent,
    b.storeLive == a.storeLive,
    b.parentTools == a.parentTools,
    b.parentWeb == a.parentWeb,
    b.parentThinking == a.parentThinking,
    b.mode == a.mode,
    b.childTools == a.childTools,
    b.childWeb == a.childWeb,
    b.childThinking == a.childThinking,
  }

  pure def absNext(a: Abs, b: Abs): bool = or {
    a == b,
    deriveChild(a, b),
    clearChild(a, b),
    storeLogin(a, b),
    storeLogout(a, b),
    storeExpire(a, b),
    storeRefresh(a, b),
    startRequest(a, b),
    endRequest(a, b),
  }

  // ---- properties ----

  // Child tools are always narrowed by parent authority.
  pure def toolsNarrowed(a: Abs): bool =
    a.childTools.subseteq(a.parentTools)

  // Background jobs are strictly read-only (mutating tools excluded).
  pure def backgroundReadOnly(a: Abs): bool =
    a.mode == "background" implies a.childTools.intersect(MUTATING) == Set()

  // Hosted web search is never enabled if disabled in parent.
  pure def noWiderNetwork(a: Abs): bool =
    not(a.parentWeb) implies not(a.childWeb)

  // Thinking level is a recognized level.
  pure def validThinking(a: Abs): bool = and {
    LEVELS.contains(a.parentThinking),
    a.mode != "none" implies LEVELS.contains(a.childThinking),
  }

  // No active request carries an expired or unauthenticated credential.
  pure def noStaleRequest(a: Abs): bool =
    a.reqActive implies a.reqTokenLive

  // A live token in the store implies credentials are present.
  pure def tokenLiveImpliesPresent(a: Abs): bool =
    a.storeLive implies a.storePresent

  pure def absInv(a: Abs): bool = and {
    toolsNarrowed(a),
    backgroundReadOnly(a),
    noWiderNetwork(a),
    validThinking(a),
    noStaleRequest(a),
    tokenLiveImpliesPresent(a),
  }
}
