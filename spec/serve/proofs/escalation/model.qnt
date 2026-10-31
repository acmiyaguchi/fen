// Proof model: two-hop subagent escalation across wire + serve (#394, #398;
// serve FINDINGS V10, guarantee 10).
//
// When a child subagent (`fen --presenter rpc`) hits a decision or permission
// check, it emits `select-requested` on its wire event stream (`wire == "reqToParent"`)
// and parks its turn (`cStatus = "parked"`). The parent polls the wire stream,
// creates a relayed request (`pStatus = "pending"`) scoped to the parent turn
// and child run, and broadcasts `select-requested` to its attached serve clients / TUI.
// When any client answers (or the parent's request times out or is cancelled),
// the parent sends a `select-resolve` control (`ansToChild` or `abortToChild`)
// down the child wire channel, which the child polls and uses to unpark its turn.
//
// Because the parent and child are separate processes polling JSONL files on an
// asynchronous tick cadence, the child's countdown can tick (`tickChildInFlight`)
// while `reqToParent` or `ansToChild`/`abortToChild` is in transit across the wire
// (`cFlightUsed < MAX_FLIGHT_TICKS`). Therefore a 1-tick margin is not enough;
// the child's initial budget must exceed the parent's by more than the in-flight
// poll margin (`C_MAX_REM = P_MAX_REM + MAX_FLIGHT_TICKS + 1`).
//
// Three two-hop hazards occur if the parent/child boundary is naive (`issue`):
//   1. Child expires before parent (`CHILD_OUTLASTS = false`): the child's own
//      request timeout fires before the parent's relayed request resolves
//      (`cRem <= pRem + in-flight ticks`). A client then answers the parent's
//      still-open modal; the parent reports the answer as accepted, but the
//      child already timed out (`parentAnswerReachesChild` violated).
//   2. Orphan parent request on child exit (`CHILD_EXIT_RESOLVES = false`):
//      the child crashes, is cancelled, or hits its run deadline while the
//      parent's relayed request is open. The parent's modal stays `pending`
//      for a dead child (`noOrphanParentReq` violated).
//   3. Wedged child on parent cancel/timeout (`PARENT_END_FORWARDS = false`):
//      the parent's turn is cancelled or the parent's request times out,
//      resolving the parent's modal locally without forwarding a cancellation
//      or default resolution down the wire, leaving the running child parked
//      with no parent request driving it (`noParkedChildWithoutParent` violated).
module escalation {
  // The child's deadline budget outlasts the parent's plus the in-flight wire
  // poll margin (`C_MAX_REM = P_MAX_REM + MAX_FLIGHT_TICKS + 1`).
  const CHILD_OUTLASTS: bool
  // When the parent polls a child exit (crash, cancel, run deadline), it
  // resolves any pending relayed request for that child.
  const CHILD_EXIT_RESOLVES: bool
  // When the parent's turn ends or the parent's relayed request times out, the
  // parent forwards a cancel / default resolution down the wire to the child.
  const PARENT_END_FORWARDS: bool

  pure val P_MAX_REM = 2
  pure val MAX_FLIGHT_TICKS = 1
  pure val C_MAX_REM = 4
  pure val P_REMS = 0.to(P_MAX_REM)
  pure val C_REMS = 0.to(C_MAX_REM)
  pure val FLIGHT_REMS = 0.to(MAX_FLIGHT_TICKS)
  pure val P_STATUSES = Set("none", "pending", "answered", "timeout", "ended", "childExited")
  pure val C_STATUSES = Set("none", "parked", "resumed", "timeout", "aborted")
  pure val WIRES = Set("none", "reqToParent", "ansToChild", "abortToChild")
  pure val LABELS = Set("init", "childAsk", "parentPollReq", "clientAnswer",
    "parentTimeout", "parentCancel", "childTimeout", "childCrash",
    "parentPollChildExit", "childPollWire", "tickBoth", "tickChildInFlight")

  var pTurnOpen: bool          // parent turn is running
  var cAlive: bool             // child process is alive
  var pStatus: str             // parent relayed request status
  var cStatus: str             // child request status
  var pRem: int                // parent request countdown ticks remaining
  var cRem: int                // child request countdown ticks remaining
  var cFlightUsed: int         // child-only ticks elapsed while a wire message is in flight
  var wire: str                // in-flight wire message: "none" | "reqToParent" | "ansToChild" | "abortToChild"
  var cExitPending: bool       // child exited on wire, parent has not polled the exit yet

  // Ghost: sticky monitors
  var lostAnswer: bool         // parent accepted a client answer for a live child that already timed out
  var pResCount: int           // number of times the parent request resolved
  var cResCount: int           // number of times the child request resolved
  var lastAction: str

  action commit(pto: bool, ca: bool, ps: str, cs: str, pr: int, cr: int, cfu: int,
                w: str, cep: bool, la: bool, prc: int, crc: int, label: str): bool =
    all {
      pTurnOpen' = pto, cAlive' = ca,
      pStatus' = ps, cStatus' = cs,
      pRem' = pr, cRem' = cr, cFlightUsed' = cfu,
      wire' = w, cExitPending' = cep,
      lostAnswer' = la, pResCount' = prc, cResCount' = crc,
      lastAction' = label,
    }

  action init = all {
    pTurnOpen' = true,
    cAlive' = true,
    pStatus' = "none",
    cStatus' = "none",
    pRem' = 0,
    cRem' = 0,
    cFlightUsed' = 0,
    wire' = "none",
    cExitPending' = false,
    lostAnswer' = false,
    pResCount' = 0,
    cResCount' = 0,
    lastAction' = "init",
  }

  // 1. Child issues `select-requested` on its wire stream and parks.
  //    Under CHILD_OUTLASTS, the child's countdown is C_MAX_REM (4) > P_MAX_REM + MAX_FLIGHT_TICKS (3);
  //    under `issue`, both start with P_MAX_REM (2), so the child can expire first.
  action childAsk: bool = all {
    pTurnOpen, cAlive, cStatus == "none", pStatus == "none", wire == "none",
    commit(pTurnOpen, cAlive, "none", "parked", 0,
           if (CHILD_OUTLASTS) C_MAX_REM else P_MAX_REM, 0,
           "reqToParent", false, lostAnswer, pResCount, cResCount, "childAsk"),
  }

  // 2. Parent polls `select-requested` from the wire and opens its relayed request.
  action parentPollReq: bool = all {
    pTurnOpen, wire == "reqToParent", pStatus == "none", not(cExitPending),
    commit(pTurnOpen, cAlive, "pending", cStatus, P_MAX_REM, cRem, cFlightUsed,
           "none", cExitPending, lostAnswer, pResCount, cResCount, "parentPollReq"),
  }

  // 3. A client answers the parent's pending request: parent resolves to
  //    "answered" and sends `ansToChild` on the wire (if the child has not exited).
  action clientAnswer: bool = all {
    pTurnOpen, pStatus == "pending",
    commit(pTurnOpen, cAlive, "answered", cStatus, 0, cRem, cFlightUsed,
           if (cAlive) "ansToChild" else "none", cExitPending,
           lostAnswer or (cAlive and cStatus != "parked"),
           pResCount + 1, cResCount, "clientAnswer"),
  }

  // 4. Parent's relayed request hits its deadline (`pRem == 1`): resolves to
  //    "timeout" and, if PARENT_END_FORWARDS, sends `abortToChild` on the wire.
  action parentTimeout: bool = all {
    pStatus == "pending", pRem == 1,
    commit(pTurnOpen, cAlive, "timeout", cStatus, 0, cRem, cFlightUsed,
           if (PARENT_END_FORWARDS and cAlive) "abortToChild" else wire, cExitPending,
           lostAnswer, pResCount + 1, cResCount, "parentTimeout"),
  }

  // 5. Parent turn is cancelled: resolves pending parent request to "ended" and,
  //    if PARENT_END_FORWARDS, aborts/reaps the child.
  action parentCancel: bool =
    val wasPending = (pStatus == "pending")
    all {
      pTurnOpen,
      commit(false,
             if (PARENT_END_FORWARDS) false else cAlive,
             if (wasPending) "ended" else pStatus,
             if (PARENT_END_FORWARDS and cStatus == "parked") "aborted" else cStatus,
             0,
             if (PARENT_END_FORWARDS) 0 else cRem,
             cFlightUsed,
             if (PARENT_END_FORWARDS) "none" else wire,
             false,
             lostAnswer,
             pResCount + (if (wasPending) 1 else 0),
             cResCount + (if (PARENT_END_FORWARDS and cStatus == "parked") 1 else 0),
             "parentCancel"),
    }

  // 6a. Synchronized tick when both parent and child requests are waiting and can
  //     advance together without expiring.
  action tickBoth: bool = all {
    pStatus == "pending", cStatus == "parked", pRem > 1, cRem > 1,
    commit(pTurnOpen, cAlive, pStatus, cStatus, pRem - 1, cRem - 1, cFlightUsed,
           wire, cExitPending, lostAnswer, pResCount, cResCount, "tickBoth"),
  }

  // 6b. Asynchronous hop tick: the child's clock ticks while a wire message
  //     (`reqToParent`, `ansToChild`, or `abortToChild`) is in transit before
  //     the next poll cycle (`cFlightUsed < MAX_FLIGHT_TICKS`).
  action tickChildInFlight: bool = all {
    cAlive, cStatus == "parked", cRem > 1,
    wire != "none", cFlightUsed < MAX_FLIGHT_TICKS,
    commit(pTurnOpen, cAlive, pStatus, cStatus, pRem, cRem - 1, cFlightUsed + 1,
           wire, cExitPending, lostAnswer, pResCount, cResCount, "tickChildInFlight"),
  }

  // 7. Child's own request timer expires (`cRem == 1`) before receiving a wire resolution.
  //    Under CHILD_OUTLASTS, `cRem > pRem` while `pStatus == "pending"`, so `cRem == 1`
  //    is only reachable after the parent's request is no longer `pending` (`pRem == 0`).
  action childTimeout: bool = all {
    cAlive, cStatus == "parked", cRem == 1,
    commit(pTurnOpen, cAlive, pStatus, "timeout", pRem, 0, cFlightUsed,
           wire, cExitPending, lostAnswer, pResCount, cResCount + 1, "childTimeout"),
  }

  // 8. Child crashes or hits its run deadline while parked.
  action childCrash: bool = all {
    cAlive, cStatus == "parked",
    commit(pTurnOpen, false, pStatus, "aborted", pRem, 0, cFlightUsed,
           "none", true, lostAnswer, pResCount, cResCount + 1, "childCrash"),
  }

  // 9. Parent polls the child's exit event from the wire.
  action parentPollChildExit: bool =
    val wasPending = (pStatus == "pending")
    all {
      cExitPending,
      commit(pTurnOpen, cAlive,
             if (CHILD_EXIT_RESOLVES and wasPending) "childExited" else pStatus,
             cStatus,
             if (CHILD_EXIT_RESOLVES and wasPending) 0 else pRem,
             cRem, cFlightUsed, "none", false, lostAnswer,
             pResCount + (if (CHILD_EXIT_RESOLVES and wasPending) 1 else 0),
             cResCount, "parentPollChildExit"),
    }

  // 10. Child polls the parent's resolution control from the wire.
  action childPollWire: bool = all {
    cAlive, wire == "ansToChild" or wire == "abortToChild",
    commit(pTurnOpen, cAlive, pStatus,
           if (cStatus == "parked")
             (if (wire == "ansToChild") "resumed" else "aborted")
           else cStatus,
           pRem, 0, cFlightUsed, "none", cExitPending,
           lostAnswer or (wire == "ansToChild" and cStatus != "parked"),
           pResCount,
           cResCount + (if (cStatus == "parked") 1 else 0),
           "childPollWire"),
  }

  // Stutter when terminal so Apalache bounded/inductive checks never deadlock.
  action done: bool = all {
    not(pTurnOpen) or (pStatus != "pending" and cStatus != "parked" and wire == "none" and not(cExitPending)),
    commit(pTurnOpen, cAlive, pStatus, cStatus, pRem, cRem, cFlightUsed,
           wire, cExitPending, lostAnswer, pResCount, cResCount, lastAction),
  }

  action step = any {
    childAsk, parentPollReq, clientAnswer, parentTimeout, parentCancel,
    tickBoth, tickChildInFlight, childTimeout, childCrash,
    parentPollChildExit, childPollWire, done,
  }

  // ---- Invariants ----

  // Both parent and child requests resolve at most once.
  val resolvedAtMostOnce = pResCount <= 1 and cResCount <= 1

  // Every answer accepted by the parent while the child is alive actually
  // reaches the parked child (`cStatus == "parked"` when answered and polled).
  val parentAnswerReachesChild = not(lostAnswer)

  // Once the parent has drained the child's exit event (`not(cExitPending)`),
  // no parent request stays pending for a dead child.
  val noOrphanParentReq =
    (not(cAlive) and not(cExitPending)) implies pStatus != "pending"

  // Once the wire is drained (`wire == "none"`), the child is never left parked
  // without a pending parent request driving it.
  val noParkedChildWithoutParent =
    (cAlive and cStatus == "parked" and wire == "none") implies (pTurnOpen and pStatus == "pending")

  // Bounded-wait safety: while the parent request is pending, `1 <= pRem <= P_MAX_REM`,
  // and while both are waiting, the child's remaining budget strictly exceeds the
  // parent's plus any remaining in-flight hop budget (`cRem > pRem + (MAX_FLIGHT_TICKS - cFlightUsed)`).
  val boundedTwoHopDeadlines = and {
    (pStatus == "pending") == (pRem >= 1),
    (cAlive and cStatus == "parked") == (cRem >= 1),
    (cAlive and cStatus == "parked" and pStatus == "pending")
      implies cRem > pRem + (MAX_FLIGHT_TICKS - cFlightUsed),
  }

  val allInvariants = and {
    resolvedAtMostOnce,
    parentAnswerReachesChild,
    noOrphanParentReq,
    noParkedChildWithoutParent,
    boundedTwoHopDeadlines,
  }

  val inductiveInv = and {
    pTurnOpen.in(Bool), cAlive.in(Bool),
    pStatus.in(P_STATUSES), cStatus.in(C_STATUSES),
    pRem.in(P_REMS), cRem.in(C_REMS), cFlightUsed.in(FLIGHT_REMS),
    wire.in(WIRES), cExitPending.in(Bool),
    lostAnswer.in(Bool), pResCount.in(0.to(1)), cResCount.in(0.to(1)),
    lastAction.in(LABELS),
    pResCount == (if (pStatus == "none" or pStatus == "pending") 0 else 1),
    cResCount == (if (cStatus == "none" or cStatus == "parked") 0 else 1),
    not(pTurnOpen) implies (pStatus != "pending" and not(cAlive) and cStatus != "parked" and wire == "none" and not(cExitPending)),
    cExitPending implies (not(cAlive) and cStatus == "aborted" and wire == "none"),
    not(cAlive) implies (cStatus != "parked" and cRem == 0 and wire == "none"),
    wire == "reqToParent" implies (pTurnOpen and cAlive and cStatus == "parked" and pStatus == "none" and cRem + cFlightUsed == C_MAX_REM),
    wire == "ansToChild" implies (pTurnOpen and cAlive and pStatus == "answered" and cStatus == "parked" and cRem + cFlightUsed >= 3),
    wire == "abortToChild" implies (cAlive and pStatus == "timeout" and cStatus == "parked" and cRem + cFlightUsed >= 3),
    (pStatus == "pending" and cAlive) implies (cStatus == "parked" and wire == "none" and cRem + cFlightUsed == pRem + 2),
    (pStatus == "none" and cStatus == "parked") implies (wire == "reqToParent" and cAlive),
    (cAlive and cStatus == "parked" and pStatus != "pending" and pStatus != "none")
      implies (wire == "ansToChild" or wire == "abortToChild"),
    allInvariants,
  }
}

// Naive two-hop escalation: equal/shorter child timeout, no parent cleanup on
// child crash, and parent timeout/cancel not forwarded down the wire.
module issue {
  import escalation(CHILD_OUTLASTS = false, CHILD_EXIT_RESOLVES = false,
                    PARENT_END_FORWARDS = false).*
}

// Proposed two-hop escalation contract: child budget outlasts parent + hop
// margin, child exit resolves parent request, and parent end/timeout forwards to child.
module proposed {
  import escalation(CHILD_OUTLASTS = true, CHILD_EXIT_RESOLVES = true,
                    PARENT_END_FORWARDS = true).*
}
