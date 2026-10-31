// Proof model: request resolution (#398, serve FINDINGS #638, V2, V4-V7, V9;
// guarantees 4-8).
//
// Only the state the contract needs: the turn (running, id, which request
// it is parked on), the /reload generation, whether any remote client is
// connected, and a fixed table of request ids 1..MAX_REQS, each with its
// scope (0 = idle, a slash command's picker; t > 0 = issued inside turn t),
// the generation it was issued in, its status, how many resolutions it got,
// its choice-list version, and whether it carries a deadline.
// No client views: an answerer may hold any choice-list version up to the
// current one (shown), which over-approximates every delivery order.
//
// The integration model (../../model.qnt) has the same flags; the instances
// at the bottom are the same designs.
module requests {
  // An answer names its request id (#398); false: the web /select bare index.
  const ANSWER_BY_ID: bool
  // A late or duplicate answer gets a rejection ack (docs/wire.md).
  const ACK_ANSWERS: bool
  // Ending or cancelling a turn resolves its pending requests.
  const END_RESOLVES: bool
  // Every request is issued with a deadline.
  const TIMEOUTS: bool
  // An idle-scoped continuation re-checks idle before it acts.
  const RECHECK: bool
  // Choice refreshes are versioned; a stale answer is rejected.
  const VERSIONED: bool
  // An in-process presenter that can answer is present.
  const LOCAL: bool
  // /reload resolves the pending idle-scoped requests.
  const RELOAD_RESOLVES: bool

  pure val MAX_REQS = 3
  pure val IDS = 1.to(MAX_REQS)
  pure val MAX_TURNS = 2
  pure val MAX_GEN = 2
  pure val MAX_VER = 1
  pure val TURNS = 0.to(MAX_TURNS)
  pure val GENS = 0.to(MAX_GEN)
  pure val VERS = 0.to(MAX_VER)
  pure val STATUSES = Set("none", "pending", "answered", "timeout", "ended", "cancelled", "aborted")
  pure val LABELS = Set("init", "startTurn", "turnEnd", "cancel", "toolRequest", "cmdRequest",
    "updateChoices", "answerLate", "answerRejectedStaleChoices", "answerResumesTurn",
    "answerForEndedTurn", "answerAbortedBusy", "answerCmdWhileBusy", "answerCmd",
    "timeout", "reload", "connect", "disconnect")

  // turn
  var running: bool
  var turnNo: int
  var parkedOn: int            // request the running turn waits on, or -1
  var gen: int                 // /reload generation
  var nextReq: int
  var conn: bool               // some remote client is connected
  // request table (ids 1..MAX_REQS; "none" = not issued yet)
  var rTurn: int -> int
  var rGen: int -> int
  var rStatus: int -> str
  var rRes: int -> int         // resolutions broadcast for the request
  var rVer: int -> int
  var rDeadline: int -> bool
  // ghost: sticky, false once an applied answer broke the property
  var scopeOk: bool
  var freshOk: bool
  var verOk: bool
  var hitOk: bool
  var ackOk: bool
  var lastAction: str

  action turnTo(r: bool, t: int, p: int, g: int, n: int, c: bool): bool = all {
    running' = r, turnNo' = t, parkedOn' = p, gen' = g, nextReq' = n, conn' = c,
  }
  action keepTurn: bool = turnTo(running, turnNo, parkedOn, gen, nextReq, conn)

  action reqsTo(tu: int -> int, ge: int -> int, st: int -> str, re: int -> int,
                ve: int -> int, de: int -> bool): bool = all {
    rTurn' = tu, rGen' = ge, rStatus' = st, rRes' = re, rVer' = ve, rDeadline' = de,
  }
  action keepReqs: bool = reqsTo(rTurn, rGen, rStatus, rRes, rVer, rDeadline)

  action ghostTo(sc: bool, fr: bool, vo: bool, hi: bool, ac: bool, label: str): bool = all {
    scopeOk' = sc, freshOk' = fr, verOk' = vo, hitOk' = hi, ackOk' = ac, lastAction' = label,
  }
  action keepGhost(label: str): bool = ghostTo(scopeOk, freshOk, verOk, hitOk, ackOk, label)

  def pending(i: int): bool = rStatus.get(i) == "pending"
  def pendingIds: Set[int] = IDS.filter(i => pending(i))

  // Resolve every request in `ids` with `status`, counting one broadcast each.
  action resolve(ids: Set[int], status: str): bool =
    reqsTo(rTurn, rGen, IDS.mapBy(i => if (ids.contains(i)) status else rStatus.get(i)),
           IDS.mapBy(i => if (ids.contains(i)) rRes.get(i) + 1 else rRes.get(i)),
           rVer, rDeadline)

  action init = all {
    turnTo(false, 0, -1, 0, 1, false),
    reqsTo(IDS.mapBy(_i => 0), IDS.mapBy(_i => 0), IDS.mapBy(_i => "none"),
           IDS.mapBy(_i => 0), IDS.mapBy(_i => 0), IDS.mapBy(_i => false)),
    ghostTo(true, true, true, true, true, "init"),
  }

  action startTurn: bool = all {
    not(running), turnNo < MAX_TURNS,
    turnTo(true, turnNo + 1, -1, gen, nextReq, conn), keepReqs, keepGhost("startTurn"),
  }

  // The running turn ends (naturally only when not parked; cancel any time).
  action endTurn(label: str): bool = all {
    running,
    turnTo(false, turnNo, -1, gen, nextReq, conn),
    if (END_RESOLVES) resolve(pendingIds.filter(i => rTurn.get(i) == turnNo), "ended")
    else keepReqs,
    keepGhost(label),
  }
  action naturalEnd: bool = all { parkedOn < 0, endTurn("turnEnd") }
  action cancel: bool = endTurn("cancel")

  action openReq(scope: int, park: bool, label: str): bool =
    val i = nextReq
    all {
      i <= MAX_REQS,
      turnTo(running, turnNo, if (park) i else parkedOn, gen, i + 1, conn),
      reqsTo(rTurn.set(i, scope), rGen.set(i, gen), rStatus.set(i, "pending"),
             rRes.set(i, 0), rVer.set(i, 0), rDeadline.set(i, TIMEOUTS)),
      keepGhost(label),
    }

  // A tool or permission check inside the running turn asks and parks.
  action toolRequest: bool = all { running, parkedOn < 0, openReq(turnNo, true, "toolRequest") }

  // An idle-only slash command (/resume, /model) opens a picker.
  action cmdRequest: bool = all {
    not(running), LOCAL, pendingIds.forall(i => rTurn.get(i) != 0),
    openReq(0, false, "cmdRequest"),
  }

  // /model refreshes its choices while the picker is open.
  action updateChoices(i: int): bool = all {
    pending(i), rTurn.get(i) == 0, rVer.get(i) < MAX_VER,
    keepTurn, reqsTo(rTurn, rGen, rStatus, rRes, rVer.set(i, rVer.get(i) + 1), rDeadline),
    keepGhost("updateChoices"),
  }

  def activeReq: int = pendingIds.fold(-1, (a, i) => if (i > a) i else a)

  // An answer to `aim`, made against choice-list version `shown`, is applied.
  action applied(aim: int, target: int, shown: int, inScope: bool, park: int, label: str): bool = all {
    turnTo(running, turnNo, park, gen, nextReq, conn),
    resolve(Set(target), "answered"),
    ghostTo(scopeOk and inScope, freshOk and rGen.get(target) == gen,
            verOk and shown == rVer.get(target), hitOk and aim == target, ackOk, label),
  }

  // Someone who can answer (the TUI or a connected remote) answers `aim`.
  action answer(aim: int, shown: int): bool =
    val target = if (ANSWER_BY_ID) aim else activeReq
    all {
      LOCAL or conn, rStatus.get(aim) != "none", shown <= rVer.get(aim),
      if (target < 0 or not(pending(target)))
        all { keepTurn, keepReqs,
              ghostTo(scopeOk, freshOk, verOk, hitOk, ackOk and ACK_ANSWERS, "answerLate") }
      else if (VERSIONED and target == aim and shown != rVer.get(target))
        all { keepTurn, keepReqs, keepGhost("answerRejectedStaleChoices") }
      else if (rTurn.get(target) > 0)
        if (running and parkedOn == target)
          applied(aim, target, shown, true, -1, "answerResumesTurn")
        else
          // accepted, but the turn it was issued for is gone
          applied(aim, target, shown, false, parkedOn, "answerForEndedTurn")
      else if (running)
        if (RECHECK)
          all { keepTurn, resolve(Set(target), "aborted"), keepGhost("answerAbortedBusy") }
        else
          // the command continuation runs while a turn is running
          applied(aim, target, shown, false, parkedOn, "answerCmdWhileBusy")
      else
        applied(aim, target, shown, true, parkedOn, "answerCmd"),
    }

  action timeout(i: int): bool = all {
    rDeadline.get(i), pending(i),
    turnTo(running, turnNo, if (parkedOn == i) -1 else parkedOn, gen, nextReq, conn),
    resolve(Set(i), "timeout"), keepGhost("timeout"),
  }

  // /reload is idle-only, so only idle-scoped requests straddle it.
  action reload: bool = all {
    not(running), gen < MAX_GEN,
    turnTo(running, turnNo, parkedOn, gen + 1, nextReq, conn),
    if (RELOAD_RESOLVES) resolve(pendingIds.filter(i => rTurn.get(i) == 0), "cancelled")
    else keepReqs,
    keepGhost("reload"),
  }

  action connect: bool = all {
    turnTo(running, turnNo, parkedOn, gen, nextReq, true), keepReqs, keepGhost("connect"),
  }
  action disconnect: bool = all {
    turnTo(running, turnNo, parkedOn, gen, nextReq, false), keepReqs, keepGhost("disconnect"),
  }

  action step = {
    nondet i = IDS.oneOf()
    nondet v = VERS.oneOf()
    any {
      startTurn, naturalEnd, cancel, toolRequest, cmdRequest, updateChoices(i),
      answer(i, v), timeout(i), reload, connect, disconnect,
    }
  }

  // ---- invariants ----

  // A request is resolved (answered, timed out, ended, cancelled, aborted)
  // at most once.
  val resolvedAtMostOnce = IDS.forall(i => rRes.get(i) <= 1)
  // Every answer that loses gets a visible rejection to its sender.
  val answersAcked = ackOk
  // An answer resolves the request it was made for.
  val answerHitsItsRequest = hitOk
  // A resolution is applied only in the scope it was issued for.
  val resolutionInScope = scopeOk
  // A resolution never drives a continuation captured before a /reload.
  val noStaleContinuation = freshOk
  // An answer picks from the choice list the answerer was shown.
  val answerMatchesShownChoices = verOk
  // No request outlives the turn it was issued from.
  val noPendingForEndedTurn = pendingIds.forall(i =>
    rTurn.get(i) == 0 or (running and rTurn.get(i) == turnNo))
  // Safety, not liveness: in every state each pending request has a party
  // that could resolve it (the in-process presenter, a connected remote, or a
  // deadline armed on the request). It does not claim that anyone answers or
  // that the deadline fires: no fairness is assumed.
  val pendingHasPossibleResolver = pendingIds.forall(i => LOCAL or conn or rDeadline.get(i))

  val allInvariants = and {
    resolvedAtMostOnce, answersAcked, answerHitsItsRequest, resolutionInScope,
    noStaleContinuation, answerMatchesShownChoices, noPendingForEndedTurn,
    pendingHasPossibleResolver,
  }

  // Inductive strengthening: every variable in its finite domain; ids below
  // nextReq are issued; a request is resolved exactly when it is no longer
  // pending; the parked request is pending and belongs to the running turn;
  // a pending turn-scoped request is the one its turn is parked on; a
  // pending request was issued in the current generation; and with
  // deadlines, every request has one.
  val inductiveInv = and {
    running.in(Bool), turnNo.in(TURNS), parkedOn.in(Set(-1).union(IDS)), gen.in(GENS),
    nextReq.in(1.to(MAX_REQS + 1)), conn.in(Bool),
    rTurn.in(setOfMaps(IDS, TURNS)), rGen.in(setOfMaps(IDS, GENS)),
    rStatus.in(setOfMaps(IDS, STATUSES)), rRes.in(setOfMaps(IDS, 0.to(2))),
    rVer.in(setOfMaps(IDS, VERS)), rDeadline.in(setOfMaps(IDS, Bool)),
    scopeOk.in(Bool), freshOk.in(Bool), verOk.in(Bool), hitOk.in(Bool), ackOk.in(Bool),
    lastAction.in(LABELS),
    IDS.forall(i => (i < nextReq) == (rStatus.get(i) != "none")),
    IDS.forall(i => rRes.get(i) == (if (rStatus.get(i) == "none" or pending(i)) 0 else 1)),
    running implies turnNo >= 1,
    parkedOn >= 0 implies (running and pending(parkedOn) and rTurn.get(parkedOn) == turnNo),
    IDS.forall(i => (pending(i) and rTurn.get(i) > 0) implies parkedOn == i),
    IDS.forall(i => pending(i) implies rGen.get(i) == gen),
    TIMEOUTS implies IDS.forall(i => pending(i) implies rDeadline.get(i)),
    allInvariants,
  }
}

// #398 as written, with the TUI attached.
module issue {
  import requests(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
                  TIMEOUTS = false, RECHECK = false, VERSIONED = false, LOCAL = true,
                  RELOAD_RESOLVES = false).*
}

// #398 beside a headless presenter: no in-process answerer.
module headless {
  import requests(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
                  TIMEOUTS = false, RECHECK = false, VERSIONED = false, LOCAL = false,
                  RELOAD_RESOLVES = false).*
}

// The web /select handler #396 says to reuse: a bare index for the active select.
module webReuse {
  import requests(ANSWER_BY_ID = false, ACK_ANSWERS = false, END_RESOLVES = false,
                  TIMEOUTS = false, RECHECK = false, VERSIONED = false, LOCAL = true,
                  RELOAD_RESOLVES = false).*
}

// The proposed protocol, headless and with the TUI.
module proposed {
  import requests(ANSWER_BY_ID = true, ACK_ANSWERS = true, END_RESOLVES = true,
                  TIMEOUTS = true, RECHECK = true, VERSIONED = true, LOCAL = false,
                  RELOAD_RESOLVES = true).*
}

module proposedTui {
  import requests(ANSWER_BY_ID = true, ACK_ANSWERS = true, END_RESOLVES = true,
                  TIMEOUTS = true, RECHECK = true, VERSIONED = true, LOCAL = true,
                  RELOAD_RESOLVES = true).*
}
