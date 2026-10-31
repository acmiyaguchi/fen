// Deterministic witnesses: the inheritance function on one configuration.
module witnesses {
  import inheritance(FIXES = Set()) as C from "./model"
  import inheritance(FIXES = Set("645", "650")) as F from "./model"

  pure val PLAIN: C::Config = {
    provider: "anthropic", level: "off", fmThinking: "", callThinking: "",
    parentWeb: "", settingsWeb: "off", mode: "blocking", agentTools: "all",
    parentDenyBash: false,
  }

  // #645: a thinking parent forwards its status label as --thinking.
  run w645StatusLabelForwardedTest =
    C::initWith({ ...PLAIN, level: "high" })
      .expect(not(C::inheritedRoutingAccepted) and not(C::thinkingInherited)
              and C::childThinking(C::cfg) == "think:8192")

  // #645 on OpenAI: the effort label is rejected too.
  run w645EffortLabelForwardedTest =
    C::initWith({ ...PLAIN, provider: "openai", level: "high" })
      .expect(not(C::inheritedRoutingAccepted) and C::childThinking(C::cfg) == "reason:high")

  // #650: a background child keeps edit and bash.
  run w650BackgroundMutatesTest =
    C::initWith({ ...PLAIN, mode: "background" })
      .expect(not(C::backgroundReadOnly) and C::childTools(C::cfg) == Set("read", "edit", "bash"))

  // #650: --web-search off on the parent, live in settings: the child is live.
  run w650WebSearchOffDroppedTest =
    C::initWith({ ...PLAIN, parentWeb: "off", settingsWeb: "live" })
      .expect(not(C::noWiderNetwork) and C::childWeb(C::cfg) == "live")

  // ---- the fixed function on the interesting configurations ----

  run reachLevelInheritedTest =
    F::initWith({ ...PLAIN, level: "high", mode: "background", parentWeb: "off",
                  settingsWeb: "live" })
      .expect(F::allInvariants and F::childThinking(F::cfg) == "high"
              and F::childTools(F::cfg) == Set("read") and F::childWeb(F::cfg) == "off")

  run reachOverrideAndLiveWebTest =
    F::initWith({ ...PLAIN, level: "high", callThinking: "xhigh", parentWeb: "live",
                  parentDenyBash: true })
      .expect(F::allInvariants and F::childThinking(F::cfg) == "xhigh"
              and F::childTools(F::cfg) == Set("read", "edit") and F::childWeb(F::cfg) == "live")
}
