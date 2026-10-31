// Reachability witnesses for the dispatch proof model: every path can run a
// tool, so the invariants do not pass because nothing executes.
module witnesses {
  import dispatch.* from "./model"

  run reachDirectExecutesTest =
    callWith("none", Set(), "direct", "bash", "allow", true, false, Set())
      .then(stutter).expect(executed and deniedUnreachable)

  run reachSideChatExecutesTest =
    callWith("deny", Set("bash"), "sidechat", "grep", "allow", true, false, Set())
      .then(stutter).expect(executed and sideChatReadOnly)

  run reachSubagentExecutesTest =
    callWith("allow", Set("edit", "read"), "subagent", "edit", "allow", true,
                       true, Set("edit", "bash"))
      .then(stutter).expect(executed and deniedUnreachable)

  run reachDeniedRefusedTest =
    callWith("deny", Set("bash"), "subagent", "bash", "allow", true,
                       true, Set("bash"))
      .then(stutter).expect(not(executed))
}
