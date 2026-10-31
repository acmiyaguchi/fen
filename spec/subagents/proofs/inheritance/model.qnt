// Proof model: child inheritance as a finite configuration function (#645,
// #650). Not a state machine: `init` picks one parent configuration, `step`
// stutters, and every invariant is a property of the pure function
//
//   parent settings + launch mode + agent frontmatter  ->  child argv + policy
//
// so the check is "for every configuration in the finite domain". Mirrors
// extensions/behaviors/companions/subagent/init.fnl (`effective-routing`,
// `child-tool-policy`, `child-argv`, `task-with-cwd-context`),
// packages/fen/src/fen/interactive.fnl (`thinking-status`), and the child's
// flag checks and settings defaults in packages/fen/src/fen/main.fnl.
//
// Abstractions: `edit` stands for every mutating tool (edit, write); `bash`
// for the shell; `read` for the read-only tools. A parent's own tool policy
// is one denial (bash), enough to show that a denial still narrows the child.
// Thinking budgets are named by their label: Anthropic shows a budget
// ("think:8192"), OpenAI an effort ("reason:high").
module inheritance {
  // "645": inherit the parent's materialized level, never the status label.
  // "650": derive the child policy: background runs lose edit and bash, and
  //        the parent's effective web search is forwarded.
  const FIXES: Set[str]

  type Config = {
    provider: str,       // "anthropic" | "openai"
    level: str,          // parent's materialized level: "off" | "low" | "high"
    fmThinking: str,     // agent frontmatter `thinking`, "" = unset
    callThinking: str,   // call argument `thinking`, "" = unset
    parentWeb: str,      // parent --web-search: "" (unset) | "off" | "live"
    settingsWeb: str,    // settings.json defaultWebSearch: "off" | "live"
    mode: str,           // "blocking" | "background"
    agentTools: str,     // frontmatter tools: "all" | "readonly"
    parentDenyBash: bool,
  }

  pure val LEVELS = Set("off", "minimal", "low", "medium", "high", "xhigh")
  pure val MUTATING = Set("edit", "bash")

  pure val CONFIGS: Set[Config] = tuples(
    Set("anthropic", "openai"), Set("off", "low", "high"), Set("", "low"),
    Set("", "xhigh"), Set("", "off", "live"), Set("off", "live"),
    Set("blocking", "background"), Set("all", "readonly"), Set(true, false)
  ).map(t => {
    provider: t._1, level: t._2, fmThinking: t._3, callThinking: t._4,
    parentWeb: t._5, settingsWeb: t._6, mode: t._7, agentTools: t._8,
    parentDenyBash: t._9,
  })

  // interactive.thinking-status: the status-bar label; false (none) when off.
  pure def statusLabel(cfg: Config): str =
    if (cfg.level == "off") ""
    else if (cfg.provider == "openai") (if (cfg.level == "high") "reason:high" else "reason:low")
    else (if (cfg.level == "high") "think:8192" else "think:1024")

  pure def override(cfg: Config): str =
    if (cfg.callThinking != "") cfg.callThinking else cfg.fmThinking

  // effective-routing's thinking: the call/frontmatter value, else (today)
  // ctx.opts.thinking (never set), ctx.agent.thinking (no such field), then
  // ctx.agent.thinking-status.
  pure def childThinking(cfg: Config): str =
    if (override(cfg) != "") override(cfg)
    else if (FIXES.contains("645")) (if (cfg.level == "off") "" else cfg.level)
    else statusLabel(cfg)

  // The child's main rejects any --thinking that is not a level (exit 2).
  pure def childAccepts(cfg: Config): bool =
    childThinking(cfg) == "" or LEVELS.contains(childThinking(cfg))

  pure def parentEffectiveWeb(cfg: Config): str =
    if (cfg.parentWeb != "") cfg.parentWeb else cfg.settingsWeb

  // child-argv forwards no --web-search today; the child applies settings.
  pure def argvWeb(cfg: Config): str =
    if (FIXES.contains("650")) parentEffectiveWeb(cfg) else ""

  pure def childWeb(cfg: Config): str =
    if (argvWeb(cfg) != "") argvWeb(cfg) else cfg.settingsWeb

  pure def parentTools(cfg: Config): Set[str] =
    if (cfg.parentDenyBash) Set("read", "edit") else Set("read", "edit", "bash")

  // child-tool-policy narrows by the parent's policy; background authority
  // is prompt text only today.
  pure def childTools(cfg: Config): Set[str] =
    val base = if (cfg.agentTools == "all") Set("read", "edit", "bash") else Set("read")
    val narrowed = base.intersect(parentTools(cfg))
    if (FIXES.contains("650") and cfg.mode == "background") narrowed.exclude(MUTATING)
    else narrowed

  var cfg: Config

  action initWith(x: Config): bool = cfg' = x
  action init = { nondet x = CONFIGS.oneOf() initWith(x) }
  action step = cfg' = cfg

  // ---- properties ----

  // The child accepts the routing it inherits.
  val inheritedRoutingAccepted = childAccepts(cfg)

  // With no override, the child runs at the parent's level.
  val thinkingInherited =
    override(cfg) == "" implies
      childThinking(cfg) == (if (cfg.level == "off") "" else cfg.level)

  // A call or frontmatter value wins.
  val overrideWins = override(cfg) != "" implies childThinking(cfg) == override(cfg)

  // Background jobs are read-only.
  val backgroundReadOnly =
    cfg.mode == "background" implies childTools(cfg).intersect(MUTATING) == Set()

  // A child never has hosted web search its parent turned off.
  val noWiderNetwork = parentEffectiveWeb(cfg) == "off" implies childWeb(cfg) == "off"

  // A child never has a tool its parent lacks.
  val toolsNarrowed = childTools(cfg).subseteq(parentTools(cfg))

  // The properties today's function already has.
  val holdsToday = overrideWins and toolsNarrowed

  // Inductive forms for Apalache: the domain constraint comes first so the
  // induction step starts from a configuration, not an arbitrary record.
  val holdsTodayInductive = and { cfg.in(CONFIGS), holdsToday }

  val allInvariants = and {
    inheritedRoutingAccepted, thinkingInherited, overrideWins,
    backgroundReadOnly, noWiderNetwork, toolsNarrowed,
  }

  val allInductive = and { cfg.in(CONFIGS), allInvariants }
}

module current { import inheritance(FIXES = Set()).* }
module fixed { import inheritance(FIXES = Set("645", "650")).* }
module fix645 { import inheritance(FIXES = Set("645")).* }
module fix650 { import inheritance(FIXES = Set("650")).* }
