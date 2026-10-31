// Reachability of the abstract policy and credential resolution machine (#675).
module witnesses {
  import policyAbstract.* from "./abstract"
  import policySpec as P from "./model"

  // Background child strips mutating tools and runs read-only.
  run reachBackgroundReadOnlyTest =
    P::init.then(P::doDeriveChild("background", ""))
      .expect(P::a.childTools == Set("read") and P::allInvariants)

  // Explicit thinking override wins over parent thinking level.
  run reachThinkingOverrideTest =
    P::init.then(P::doDeriveChild("blocking", "high"))
      .expect(P::a.childThinking == "high" and P::allInvariants)

  // Auth token expires, refreshes, and resolves live for request.
  run reachExpireRefreshRequestTest =
    P::init.then(P::doStoreExpire).then(P::doStoreRefresh)
      .then(P::doStartRequest).then(P::doEndRequest)
      .expect(not(P::a.reqActive) and P::a.storeLive and P::allInvariants)

  // Child policy is cleared when the child finishes.
  run reachClearChildTest =
    P::init.then(P::doDeriveChild("blocking", "")).then(P::doClearChild)
      .expect(P::a.mode == "none" and P::a.childTools == Set() and P::allInvariants)
}
