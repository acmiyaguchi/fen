// Proof model: request resolution (#398, serve FINDINGS #638, V2, V4-V7, V9;
// guarantees 4-8), with countdown tick budgets and step-by-step refinement of
// `spec/core/tasks/abstract.qnt` (#671).
//
// Only the state the contract needs: the turn (running, id, which request
// it is parked on), the /reload generation, whether any remote client is
// connected, and a fixed table of request ids 1..MAX_REQS, each with its
// scope (0 = idle, a slash command's picker; t > 0 = issued inside turn t),
// the generation it was issued in, its status, how many resolutions it got,
// its choice-list version, whether it carries a deadline, and its remaining
// countdown ticks (`rRem`).
// No client views: an answerer may hold any choice-list version up to the
// current one (shown), which over-approximates every delivery order.
//
// The integration model (../../model.qnt) has the same flags; the instances
// at the bottom are the same designs.
module requests {
  import requestsAbstract.* from "../../../core/tasks/abstract"

  // An answer names its request id (#398); false: the web /select bare index.
  const ANSWER_BY_ID: bool
  // A late or duplicate answer gets a rejection ack (docs/wire.md).
  const ACK_ANSWERS: bool
  // Ending or cancelling a turn resolves its pending requests.
  const END_RESOLVES: bool
  // Every request is issued with a deadline (countdown budget `MAX_BUDGET` ticks,
  // and immediate resolution to default when no resolver is present).
  const TIMEOUTS: bool
  // An idle-scoped continuation re-checks idle before it acts.
  const RECHECK: bool
  // Choice refreshes are versioned; a stale answer is rejected.
  const VERSIONED: bool
  // An in-process presenter that can answer is present.
  const LOCAL: bool
  // /reload resolves the pending idle-scoped requests.
  const RELOAD_RESOLVES: bool

  pure val MAX_REQS = 2
  pure val MAX_TURNS = 2
  pure val MAX_GEN = 2
  pure val MAX_VER = 1
  pure val MAX_BUDGET = 2
  pure val TURNS = 0.to(MAX_TURNS)
  pure val GENS = 0.to(MAX_GEN)
  pure val VERS = 0.to(MAX_VER)
  pure val REMS = 0.to(MAX_BUDGET)
  pure val LABELS = Set("init", "startTurn", "turnEnd", "cancel", "toolRequest", "cmdRequest",
    "toolRequestFallback", "cmdRequestFallback", "updateChoices", "answerLate",
    "answerRejectedStaleChoices", "answerResumesTurn", "answerForEndedTurn",
    "answerAbortedBusy", "answerCmdWhileBusy", "answerCmd", "tick", "timeout",
    "reload", "connect", "disconnect")

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
  var rRem: int -> int         // remaining countdown ticks while pending (0 when not armed/pending)
  // ghost: sticky, false once an applied answer broke the property or a step failed refinement
  var scopeOk: bool
  var freshOk: bool
  var verOk: bool
  var hitOk: bool
  var ackOk: bool
  var stepRefinesOk: bool
  var lastAction: str

  // Projection onto the abstract `requestsAbstract::ReqAbs` state (#671).
  def absOf: ReqAbs = {
    running: running,
    turnNo: turnNo,
    parkedOn: parkedOn,
    gen: gen,
    hasResolver: LOCAL or conn,
    queue: Set(),
    sLen: 0,
    fLen: 0,
    idleStart: false,
    rScope: rTurn,
    rGen: rGen,
    rVer: rVer,
    rStatus: rStatus,
    rRes: rRes,
    rRem: rRem,
  }

  pure def mkAbs(r: bool, t: int, p: int, g: int, c: bool,
                 tu: int -> int, ge: int -> int, ve: int -> int,
                 st: int -> str, re: int -> int, rm: int -> int): ReqAbs = {
    running: r, turnNo: t, parkedOn: p, gen: g, hasResolver: LOCAL or c,
    queue: Set(), sLen: 0, fLen: 0, idleStart: false, rScope: tu, rGen: ge, rVer: ve, rStatus: st, rRes: re, rRem: rm,
  }

  action commit(r: bool, t: int, p: int, g: int, n: int, c: bool,
                tu: int -> int, ge: int -> int, st: int -> str, re: int -> int,
                ve: int -> int, de: int -> bool, rm: int -> int,
                sc: bool, fr: bool, vo: bool, hi: bool, ac: bool, label: str): bool =
    val nextAbs = mkAbs(r, t, p, g, c, tu, ge, ve, st, re, rm)
    all {
      running' = r, turnNo' = t, parkedOn' = p, gen' = g, nextReq' = n, conn' = c,
      rTurn' = tu, rGen' = ge, rStatus' = st, rRes' = re, rVer' = ve, rDeadline' = de, rRem' = rm,
      scopeOk' = sc, freshOk' = fr, verOk' = vo, hitOk' = hi, ackOk' = ac,
      stepRefinesOk' = (stepRefinesOk and reqAbsNext(absOf, nextAbs)),
      lastAction' = label,
    }

  def pending(i: int): bool = rStatus.get(i) == "pending"
  def pendingIds: Set[int] = IDS.filter(i => pending(i))

  pure def resolveSt(st: int -> str, ids: Set[int], status: str): int -> str =
    IDS.mapBy(i => if (ids.contains(i)) status else st.get(i))

  pure def resolveRe(re: int -> int, ids: Set[int]): int -> int =
    IDS.mapBy(i => if (ids.contains(i)) re.get(i) + 1 else re.get(i))

  pure def resolveRm(rm: int -> int, ids: Set[int]): int -> int =
    IDS.mapBy(i => if (ids.contains(i)) 0 else rm.get(i))

  action init = all {
    running' = false, turnNo' = 0, parkedOn' = -1, gen' = 0, nextReq' = 1, conn' = false,
    rTurn' = IDS.mapBy(_i => 0), rGen' = IDS.mapBy(_i => 0), rStatus' = IDS.mapBy(_i => "none"),
    rRes' = IDS.mapBy(_i => 0), rVer' = IDS.mapBy(_i => 0), rDeadline' = IDS.mapBy(_i => false),
    rRem' = IDS.mapBy(_i => 0),
    scopeOk' = true, freshOk' = true, verOk' = true, hitOk' = true, ackOk' = true,
    stepRefinesOk' = true, lastAction' = "init",
  }

  action startTurn: bool = all {
    not(running), turnNo < MAX_TURNS,
    commit(true, turnNo + 1, -1, gen, nextReq, conn,
           rTurn, rGen, rStatus, rRes, rVer, rDeadline, rRem,
           scopeOk, freshOk, verOk, hitOk, ackOk, "startTurn"),
  }

  // The running turn ends (naturally only when not parked; cancel any time).
  action endTurn(label: str): bool =
    val own = pendingIds.filter(i => rTurn.get(i) == turnNo)
    all {
      running,
      if (END_RESOLVES)
        commit(false, turnNo, -1, gen, nextReq, conn,
               rTurn, rGen, resolveSt(rStatus, own, "ended"), resolveRe(rRes, own),
               rVer, rDeadline, resolveRm(rRem, own),
               scopeOk, freshOk, verOk, hitOk, ackOk, label)
      else
        commit(false, turnNo, -1, gen, nextReq, conn,
               rTurn, rGen, rStatus, rRes, rVer, rDeadline, rRem,
               scopeOk, freshOk, verOk, hitOk, ackOk, label),
    }

  action naturalEnd: bool = all { parkedOn < 0, endTurn("turnEnd") }
  action cancel: bool = endTurn("cancel")

  // Issue a request. Under TIMEOUTS, if no resolver (neither local presenter
  // nor connected remote) is present, the request resolves at once to its
  // default ("timeout") without parking (Required guarantee 8); otherwise it
  // starts with countdown budget `MAX_BUDGET`.
  action openReq(scope: int, park: bool, label: str, fallbackLabel: str): bool =
    val i = nextReq
    val hasRes = LOCAL or conn
    all {
      i <= MAX_REQS,
      if (TIMEOUTS and not(hasRes))
        commit(running, turnNo, parkedOn, gen, i + 1, conn,
               rTurn.set(i, scope), rGen.set(i, gen), rStatus.set(i, "timeout"),
               rRes.set(i, 1), rVer.set(i, 0), rDeadline.set(i, true), rRem.set(i, 0),
               scopeOk, freshOk, verOk, hitOk, ackOk, fallbackLabel)
      else
        commit(running, turnNo, if (park) i else parkedOn, gen, i + 1, conn,
               rTurn.set(i, scope), rGen.set(i, gen), rStatus.set(i, "pending"),
               rRes.set(i, 0), rVer.set(i, 0), rDeadline.set(i, TIMEOUTS),
               rRem.set(i, if (TIMEOUTS) MAX_BUDGET else 0),
               scopeOk, freshOk, verOk, hitOk, ackOk, label),
    }

  // A tool or permission check inside the running turn asks and parks.
  action toolRequest: bool = all {
    running, parkedOn < 0,
    openReq(turnNo, true, "toolRequest", "toolRequestFallback"),
  }

  // An idle-only slash command (/resume, /model) opens a picker.
  action cmdRequest: bool = all {
    not(running), LOCAL, pendingIds.forall(i => rTurn.get(i) != 0),
    openReq(0, false, "cmdRequest", "cmdRequestFallback"),
  }

  // /model refreshes its choices while the picker is open.
  action updateChoices(i: int): bool = all {
    pending(i), rTurn.get(i) == 0, rVer.get(i) < MAX_VER,
    commit(running, turnNo, parkedOn, gen, nextReq, conn,
           rTurn, rGen, rStatus, rRes, rVer.set(i, rVer.get(i) + 1), rDeadline, rRem,
           scopeOk, freshOk, verOk, hitOk, ackOk, "updateChoices"),
  }

  def activeReq: int = pendingIds.fold(-1, (a, i) => if (i > a) i else a)

  // An answer to `aim`, made against choice-list version `shown`, is applied.
  action applied(aim: int, target: int, shown: int, inScope: bool, park: int, label: str): bool =
    commit(running, turnNo, park, gen, nextReq, conn,
           rTurn, rGen, resolveSt(rStatus, Set(target), "answered"),
           resolveRe(rRes, Set(target)), rVer, rDeadline, resolveRm(rRem, Set(target)),
           scopeOk and inScope, freshOk and rGen.get(target) == gen,
           verOk and shown == rVer.get(target), hitOk and aim == target, ackOk, label)

  // Someone who can answer (the TUI or a connected remote) answers `aim`.
  action answer(aim: int, shown: int): bool =
    val target = if (ANSWER_BY_ID) aim else activeReq
    all {
      LOCAL or conn, rStatus.get(aim) != "none", shown <= rVer.get(aim),
      if (target < 0 or not(pending(target)))
        commit(running, turnNo, parkedOn, gen, nextReq, conn,
               rTurn, rGen, rStatus, rRes, rVer, rDeadline, rRem,
               scopeOk, freshOk, verOk, hitOk, ackOk and ACK_ANSWERS, "answerLate")
      else if (VERSIONED and target == aim and shown != rVer.get(target))
        commit(running, turnNo, parkedOn, gen, nextReq, conn,
               rTurn, rGen, rStatus, rRes, rVer, rDeadline, rRem,
               scopeOk, freshOk, verOk, hitOk, ackOk, "answerRejectedStaleChoices")
      else if (rTurn.get(target) > 0)
        if (running and parkedOn == target)
          applied(aim, target, shown, true, -1, "answerResumesTurn")
        else
          // accepted, but the turn it was issued for is gone
          applied(aim, target, shown, false, parkedOn, "answerForEndedTurn")
      else if (running)
        if (RECHECK)
          commit(running, turnNo, parkedOn, gen, nextReq, conn,
                 rTurn, rGen, resolveSt(rStatus, Set(target), "aborted"),
                 resolveRe(rRes, Set(target)), rVer, rDeadline, resolveRm(rRem, Set(target)),
                 scopeOk, freshOk, verOk, hitOk, ackOk, "answerAbortedBusy")
        else
          // the command continuation runs while a turn is running
          applied(aim, target, shown, false, parkedOn, "answerCmdWhileBusy")
      else
        applied(aim, target, shown, true, parkedOn, "answerCmd"),
    }

  // Countdown tick on a request with an armed deadline: decrements `rRem` when
  // `rRem > 1`, and fires `timeout` when `rRem == 1` (or directly via `timeout`).
  action tick(i: int): bool = all {
    rDeadline.get(i), pending(i), rRem.get(i) > 1,
    commit(running, turnNo, parkedOn, gen, nextReq, conn,
           rTurn, rGen, rStatus, rRes, rVer, rDeadline, rRem.set(i, rRem.get(i) - 1),
           scopeOk, freshOk, verOk, hitOk, ackOk, "tick"),
  }

  action timeout(i: int): bool = all {
    rDeadline.get(i), pending(i),
    commit(running, turnNo, if (parkedOn == i) -1 else parkedOn, gen, nextReq, conn,
           rTurn, rGen, resolveSt(rStatus, Set(i), "timeout"),
           resolveRe(rRes, Set(i)), rVer, rDeadline, resolveRm(rRem, Set(i)),
           scopeOk, freshOk, verOk, hitOk, ackOk, "timeout"),
  }

  // /reload is idle-only, so only idle-scoped requests straddle it.
  action reload: bool =
    val idleP = pendingIds.filter(i => rTurn.get(i) == 0)
    all {
      not(running), gen < MAX_GEN,
      if (RELOAD_RESOLVES)
        commit(running, turnNo, parkedOn, gen + 1, nextReq, conn,
               rTurn, rGen, resolveSt(rStatus, idleP, "cancelled"),
               resolveRe(rRes, idleP), rVer, rDeadline, resolveRm(rRem, idleP),
               scopeOk, freshOk, verOk, hitOk, ackOk, "reload")
      else
        commit(running, turnNo, parkedOn, gen + 1, nextReq, conn,
               rTurn, rGen, rStatus, rRes, rVer, rDeadline, rRem,
               scopeOk, freshOk, verOk, hitOk, ackOk, "reload"),
    }

  action connect: bool =
    commit(running, turnNo, parkedOn, gen, nextReq, true,
           rTurn, rGen, rStatus, rRes, rVer, rDeadline, rRem,
           scopeOk, freshOk, verOk, hitOk, ackOk, "connect")

  action disconnect: bool =
    commit(running, turnNo, parkedOn, gen, nextReq, false,
           rTurn, rGen, rStatus, rRes, rVer, rDeadline, rRem,
           scopeOk, freshOk, verOk, hitOk, ackOk, "disconnect")

  action step = {
    nondet i = IDS.oneOf()
    nondet v = VERS.oneOf()
    any {
      startTurn, naturalEnd, cancel, toolRequest, cmdRequest, updateChoices(i),
      answer(i, v), tick(i), timeout(i), reload, connect, disconnect,
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
  // Safety + bounded-progress: in every state each pending request has a party
  // that could resolve it (the in-process presenter, a connected remote, or an
  // active countdown budget `rRem >= 1` armed on the request).
  val pendingHasPossibleResolver = pendingIds.forall(i =>
    LOCAL or conn or (rDeadline.get(i) and rRem.get(i) >= 1))
  // Refinement of the `spec/core/tasks` abstract machine (#671): every step is
  // a valid `reqAbsNext` transition (or stutter), and state satisfies `reqAbsInv`.
  val refinesTasks = stepRefinesOk
  val inheritsTasksInvariants = reqAbsInv(absOf)

  val allInvariants = and {
    resolvedAtMostOnce, answersAcked, answerHitsItsRequest, resolutionInScope,
    noStaleContinuation, answerMatchesShownChoices, noPendingForEndedTurn,
    pendingHasPossibleResolver, refinesTasks, inheritsTasksInvariants,
  }

  // Inductive strengthening: every variable in its finite domain; ids below
  // nextReq are issued; a request is resolved exactly when it is no longer
  // pending; the parked request is pending and belongs to the running turn;
  // a pending turn-scoped request is the one its turn is parked on; a
  // pending request was issued in the current generation; and with
  // deadlines, every pending request has `rDeadline` and `1 <= rRem <= MAX_BUDGET`.
  val inductiveInv = and {
    running.in(Bool), turnNo.in(TURNS), parkedOn.in(Set(-1).union(IDS)), gen.in(GENS),
    nextReq.in(1.to(MAX_REQS + 1)), conn.in(Bool),
    rTurn.in(setOfMaps(IDS, TURNS)), rGen.in(setOfMaps(IDS, GENS)),
    rStatus.in(setOfMaps(IDS, STATUSES)), rRes.in(setOfMaps(IDS, 0.to(2))),
    rVer.in(setOfMaps(IDS, VERS)), rDeadline.in(setOfMaps(IDS, Bool)),
    rRem.in(setOfMaps(IDS, REMS)),
    scopeOk.in(Bool), freshOk.in(Bool), verOk.in(Bool), hitOk.in(Bool), ackOk.in(Bool),
    stepRefinesOk.in(Bool), lastAction.in(LABELS),
    IDS.forall(i => (i < nextReq) == (rStatus.get(i) != "none")),
    IDS.forall(i => rRes.get(i) == (if (rStatus.get(i) == "none" or pending(i)) 0 else 1)),
    running implies turnNo >= 1,
    IDS.forall(i => rTurn.get(i) <= turnNo),
    IDS.forall(i => rGen.get(i) <= gen),
    parkedOn >= 0 implies (running and pending(parkedOn) and rTurn.get(parkedOn) == turnNo),
    IDS.forall(i => (pending(i) and rTurn.get(i) > 0) implies parkedOn == i),
    IDS.forall(i => pending(i) implies rGen.get(i) == gen),
    IDS.forall(i => not(pending(i)) implies rRem.get(i) == 0),
    TIMEOUTS implies IDS.forall(i => pending(i) implies (rDeadline.get(i) and rRem.get(i) >= 1)),
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
