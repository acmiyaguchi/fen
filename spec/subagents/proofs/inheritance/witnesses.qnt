// Deterministic witnesses: the inheritance function on one configuration.
module witnesses {
  import inheritance(FIXES = Set()) as C from "./model"
  import inheritance(FIXES = Set("645", "650")) as F from "./model"

  pure val PLAIN: C::Config = {
    provider: "anthropic", level: "off", fmThinking: "", callThinking: "",
    parentWeb: "", settingsWeb: "off", mode: "blocking", agentTools: "all",
    parentDenyBash: false,
  }

  // #645: a thinking parent forwards its level as --thinking.
  run reach645StatusLabelForwardedTest =
    F::initWith({ ...PLAIN, level: "high" })
      .expect(F::inheritedRoutingAccepted and F::thinkingInherited
              and F::childThinking(F::cfg) == "high")

  // #645 on OpenAI: the level is accepted.
  run reach645EffortLabelForwardedTest =
    F::initWith({ ...PLAIN, provider: "openai", level: "high" })
      .expect(F::inheritedRoutingAccepted and F::childThinking(F::cfg) == "high")

  // #650: a background child is read-only.
  run reach650BackgroundMutatesTest =
    F::initWith({ ...PLAIN, mode: "background" })
      .expect(F::backgroundReadOnly and F::childTools(F::cfg) == Set("read"))

  // #650: --web-search off on the parent is inherited by the child.
  run reach650WebSearchOffDroppedTest =
    F::initWith({ ...PLAIN, parentWeb: "off", settingsWeb: "live" })
      .expect(F::noWiderNetwork and F::childWeb(F::cfg) == "off")

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
