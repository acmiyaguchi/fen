// Deterministic witnesses (quint test) for the two-hop subagent escalation
// proof model (`spec/serve/proofs/escalation`).
module witnesses {
  import escalation(CHILD_OUTLASTS = false, CHILD_EXIT_RESOLVES = false,
                    PARENT_END_FORWARDS = false) as I from "./model"
  import escalation(CHILD_OUTLASTS = true, CHILD_EXIT_RESOLVES = true,
                    PARENT_END_FORWARDS = true) as P from "./model"

  // #398 (V10a): child and parent start with equal deadline budgets (`cRem == pRem == 2`);
  // after one in-flight tick (`tickChildInFlight`) while `reqToParent` is on the wire,
  // the child times out first (`childTimeout`) while the parent modal is still open;
  // the client's accepted answer arrives after the child already gave up.
  run w398ChildExpiresBeforeParentAnswerTest =
    I::init.then(I::childAsk).then(I::tickChildInFlight).then(I::parentPollReq)
      .then(I::childTimeout).then(I::clientAnswer)
      .expect(not(I::parentAnswerReachesChild) and I::pStatus == "answered"
              and I::cStatus == "timeout")

  // #398 (V10a): without `CHILD_OUTLASTS`, `cRem == pRem` violates `boundedTwoHopDeadlines`
  // as soon as the parent opens its relayed request.
  run w398EqualDeadlinesViolatedTest =
    I::init.then(I::childAsk).then(I::parentPollReq)
      .expect(not(I::boundedTwoHopDeadlines) and I::pRem == I::cRem)

  // #398 (V10b): child crashes while parked, parent polls exit, but parent's
  // relayed request stays pending for the dead child.
  run w398OrphanParentReqAfterChildCrashTest =
    I::init.then(I::childAsk).then(I::parentPollReq).then(I::childCrash)
      .then(I::parentPollChildExit)
      .expect(not(I::noOrphanParentReq) and not(I::cAlive) and I::pStatus == "pending")

  // #398 (V10c): parent's relayed request times out locally without forwarding
  // an abort to the child, leaving the child parked with no parent request.
  run w398ParkedChildAfterParentTimeoutTest =
    I::init.then(I::childAsk).then(I::parentPollReq).then(I::tickBoth)
      .then(I::parentTimeout)
      .expect(not(I::noParkedChildWithoutParent) and I::pStatus == "timeout"
              and I::cStatus == "parked" and I::wire == "none")

  // ---- reachability of the proposed two-hop protocol ----

  // End-to-end answer with an asynchronous in-flight child tick:
  // child asks -> in-flight tick -> parent relays -> tickBoth -> client answers -> child resumes.
  run reachTwoHopAnswerResumesChildTest =
    P::init.then(P::childAsk).then(P::tickChildInFlight).then(P::parentPollReq)
      .then(P::tickBoth).then(P::clientAnswer).then(P::childPollWire)
      .expect(P::pStatus == "answered" and P::cStatus == "resumed"
              and P::cFlightUsed == 1 and P::inductiveInv)

  // End-to-end timeout: parent request expires first -> forwards abort -> child unparks.
  run reachParentTimeoutForwardsToChildTest =
    P::init.then(P::childAsk).then(P::parentPollReq).then(P::tickBoth)
      .then(P::parentTimeout).then(P::tickChildInFlight).then(P::childPollWire)
      .expect(P::pStatus == "timeout" and P::cStatus == "aborted" and P::inductiveInv)

  // Child crash resolves the parent's relayed request when exit is polled.
  run reachChildCrashResolvesParentReqTest =
    P::init.then(P::childAsk).then(P::parentPollReq).then(P::childCrash)
      .then(P::parentPollChildExit)
      .expect(P::pStatus == "childExited" and not(P::cAlive) and P::inductiveInv)

  // Parent turn cancel resolves the parent request and reaps the parked child.
  run reachParentCancelReapsParkedChildTest =
    P::init.then(P::childAsk).then(P::parentPollReq).then(P::parentCancel)
      .expect(P::pStatus == "ended" and P::cStatus == "aborted"
              and not(P::cAlive) and P::inductiveInv)
}
