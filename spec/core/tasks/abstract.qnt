// Abstract specification of task table (#671):
//   Part 1 (`tasksAbstract`): cooperative task table with turn-keyed ownership,
//     cancel arms, active poll cadence, and xpcall fault isolation (#635–#637, #660–#663).
//   Part 2 (`requestsAbstract`): the session holder of `fen.core.tasks`
//     (`holderAbstract`, proofs/holder: turns, exclusive jobs, steer and
//     follow-up queues) composed with async request resolution, /reload as an
//     exclusive job with a generation, and bounded park countdown budgets
//     (#638, #662, #397, #398, #686).
//
// Pure definitions only, so concrete models (`spec/serve`, `spec/serve/proofs/*`)
// can import them and check step-by-step refinement (`absNext(prevAbs, absOf(state))`).
module tasksAbstract {
  type Abs = {
    // Task slot 1
    t1Status: str,      // "none" | "ready" | "done"
    t1Owner: int,       // 0 when none; 1, 2 for owner turn
    t1Cancel: bool,     // cancel requested for task 1
    t1Armed: bool,      // cancel arm held by task 1 (second-press quit)
    // Task slot 2
    t2Status: str,      // "none" | "ready" | "done"
    t2Owner: int,       // 0 when none; 1, 2 for owner turn
    t2Cancel: bool,     // cancel requested for task 2
    t2Armed: bool,      // cancel arm held by task 2
    // Table-level scheduler state
    anyRunnable: bool,  // true iff at least one task is ready
    pollActive: bool,   // true iff polling at active cadence (matches anyRunnable)
    faultCaught: bool,  // a task fault was caught and isolated by the driver
  }

  pure val absInit: Abs = {
    t1Status: "none",
    t1Owner: 0,
    t1Cancel: false,
    t1Armed: false,
    t2Status: "none",
    t2Owner: 0,
    t2Cancel: false,
    t2Armed: false,
    anyRunnable: false,
    pollActive: false,
    faultCaught: false,
  }

  // Register a new task under owner.
  pure def spawn(a: Abs, b: Abs): bool = or {
    // Spawn in slot 1
    and {
      a.t1Status == "none",
      b.t1Status == "ready",
      b.t1Owner > 0,
      not(b.t1Cancel),
      not(b.t1Armed),
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      b.anyRunnable == true,
      b.pollActive == true,
      not(b.faultCaught),
    },
    // Spawn in slot 2
    and {
      a.t2Status == "none",
      b.t2Status == "ready",
      b.t2Owner > 0,
      not(b.t2Cancel),
      not(b.t2Armed),
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      b.anyRunnable == true,
      b.pollActive == true,
      not(b.faultCaught),
    },
  }

  // Request cancel strictly for the task matching owner.
  pure def requestCancel(a: Abs, b: Abs): bool = or {
    and {
      a.t1Status != "none",
      b.t1Cancel == true,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Armed == a.t1Armed,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      b.anyRunnable == a.anyRunnable,
      b.pollActive == a.pollActive,
      not(b.faultCaught),
    },
    and {
      a.t2Status != "none",
      b.t2Cancel == true,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Armed == a.t2Armed,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      b.anyRunnable == a.anyRunnable,
      b.pollActive == a.pollActive,
      not(b.faultCaught),
    },
  }

  // Arm cancel ladder (second-press quit) strictly for the task matching owner.
  pure def armCancel(a: Abs, b: Abs): bool = or {
    and {
      a.t1Status == "ready",
      b.t1Armed == true,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      b.anyRunnable == a.anyRunnable,
      b.pollActive == a.pollActive,
      not(b.faultCaught),
    },
    and {
      a.t2Status == "ready",
      b.t2Armed == true,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      b.anyRunnable == a.anyRunnable,
      b.pollActive == a.pollActive,
      not(b.faultCaught),
    },
  }

  // Driver step: resume ready task under xpcall.
  // Completing or faulting task disarms its cancel ladder.
  pure def driverStep(a: Abs, b: Abs): bool = or {
    // Step slot 1
    and {
      a.t1Status == "ready",
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      or {
        // Normal yield
        and { b.t1Status == "ready", b.t1Armed == a.t1Armed, not(b.faultCaught) },
        // Normal finish: disarms
        and { b.t1Status == "done", not(b.t1Armed), not(b.faultCaught) },
        // Fault caught under xpcall: task retired, disarms, scheduler survives
        and { b.t1Status == "done", not(b.t1Armed), b.faultCaught == true },
      },
      b.anyRunnable == (b.t1Status == "ready" or b.t2Status == "ready"),
      b.pollActive == b.anyRunnable,
    },
    // Step slot 2
    and {
      a.t2Status == "ready",
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      or {
        // Normal yield
        and { b.t2Status == "ready", b.t2Armed == a.t2Armed, not(b.faultCaught) },
        // Normal finish: disarms
        and { b.t2Status == "done", not(b.t2Armed), not(b.faultCaught) },
        // Fault caught under xpcall: task retired, disarms, scheduler survives
        and { b.t2Status == "done", not(b.t2Armed), b.faultCaught == true },
      },
      b.anyRunnable == (b.t1Status == "ready" or b.t2Status == "ready"),
      b.pollActive == b.anyRunnable,
    },
  }

  // Retire finished task from table.
  pure def retire(a: Abs, b: Abs): bool = or {
    // Retire slot 1
    and {
      a.t1Status == "done",
      b.t1Status == "none",
      b.t1Owner == 0,
      not(b.t1Cancel),
      not(b.t1Armed),
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      b.anyRunnable == (b.t2Status == "ready"),
      b.pollActive == b.anyRunnable,
      not(b.faultCaught),
    },
    // Retire slot 2
    and {
      a.t2Status == "done",
      b.t2Status == "none",
      b.t2Owner == 0,
      not(b.t2Cancel),
      not(b.t2Armed),
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      b.anyRunnable == (b.t1Status == "ready"),
      b.pollActive == b.anyRunnable,
      not(b.faultCaught),
    },
  }

  pure def absNext(a: Abs, b: Abs): bool = or {
    a == b,
    spawn(a, b),
    requestCancel(a, b),
    armCancel(a, b),
    driverStep(a, b),
    retire(a, b),
  }

  // ---- properties every refining owner inherits ----

  // Cancel ladder is armed only while that specific task is ready (#636, #661).
  pure def ownershipIsolated(a: Abs): bool = and {
    a.t1Armed implies a.t1Status == "ready",
    a.t2Armed implies a.t2Status == "ready",
    (a.t1Status == "none") == (a.t1Owner == 0),
    (a.t2Status == "none") == (a.t2Owner == 0),
  }

  // Active poll cadence holds iff runnable work is pending (#637).
  pure def cadenceMatchesRunnable(a: Abs): bool =
    a.pollActive == a.anyRunnable

  // anyRunnable accurately reflects presence of ready tasks.
  pure def runnableConsistency(a: Abs): bool =
    a.anyRunnable == (a.t1Status == "ready" or a.t2Status == "ready")

  // Cancel can only be requested on a registered task.
  pure def cancelRequiresRegistered(a: Abs): bool = and {
    a.t1Cancel implies a.t1Status != "none",
    a.t2Cancel implies a.t2Status != "none",
  }

  pure def absInv(a: Abs): bool = and {
    ownershipIsolated(a),
    cadenceMatchesRunnable(a),
    runnableConsistency(a),
    cancelRequiresRegistered(a),
  }
}

module requestsAbstract {
  // The session half is the proved holder design (proofs/holder, #686): who
  // holds the session (none | turn n | exclusive), its steer and follow-up
  // queues, and every line's disposition. Every session move below is one of
  // holderAbstract's pure steps (or a composition of them); this module adds
  // only the request table and the rules that tie it to the holder.
  import holderAbstract.* from "./proofs/holder/model"

  type ReqAbs = {
    ses: Session,           // the holder: kind, turn number n, hid, queues, dispositions
    parkedOn: int,          // request id the running turn is parked on, or -1
    gen: int,               // /reload generation
    hasResolver: bool,      // at least one resolver (local UI or connected remote) is present
    rScope: int -> int,     // req -> 0 (idle slash-command picker) or turn t > 0
    rGen: int -> int,       // req -> /reload generation when issued
    rVer: int -> int,       // req -> choice-list version
    rStatus: int -> str,    // req -> "none" | "pending" | "answered" | "timeout" | "ended" | "cancelled" | "aborted"
    rRes: int -> int,       // req -> number of resolution broadcasts emitted
    rRem: int -> int,       // req -> remaining tick budget while pending (0 when not pending)
  }

  pure val IDS: Set[int] = Set(1, 2)
  pure val STATUSES: Set[str] =
    Set("none", "pending", "answered", "timeout", "ended", "cancelled", "aborted")
  pure val RESOLVED_STATUSES: Set[str] =
    Set("answered", "timeout", "ended", "cancelled", "aborted")
  // A line a refining model does not track by seq (serve/proofs/requests has
  // no mailbox): outside SEQS, so its disposition updates nothing.
  pure val UNTRACKED_LINE: int = MAX_SEQ

  pure def reqAbsInit(hasRes: bool): ReqAbs = {
    ses: sessionInit,
    parkedOn: -1,
    gen: 0,
    hasResolver: hasRes,
    rScope: IDS.mapBy(_i => 0),
    rGen: IDS.mapBy(_i => 0),
    rVer: IDS.mapBy(_i => 0),
    rStatus: IDS.mapBy(_i => "none"),
    rRes: IDS.mapBy(_i => 0),
    rRem: IDS.mapBy(_i => 0),
  }

  // A turn holds the session; n is its number.
  pure def inTurn(a: ReqAbs): bool = a.ses.kind == "turn"

  pure def isPending(a: ReqAbs, i: int): bool =
    a.rStatus.get(i) == "pending"

  pure def pendingSet(a: ReqAbs): Set[int] =
    IDS.filter(i => isPending(a, i))

  pure def resolveSet(a: ReqAbs, ids: Set[int], st: str): ReqAbs = {
    ...a,
    rStatus: IDS.mapBy(i => if (ids.contains(i)) st else a.rStatus.get(i)),
    rRes: IDS.mapBy(i => if (ids.contains(i)) a.rRes.get(i) + 1 else a.rRes.get(i)),
    rRem: IDS.mapBy(i => if (ids.contains(i)) 0 else a.rRem.get(i)),
  }

  // ---- session steps (holderAbstract) ----
  // Each is a relation on the Session alone (x before, y after); `parked` is
  // the request the running turn is parked on (-1: none). The request table
  // is unchanged by these (`sameRequests`); the steps that compose request
  // resolution with the holder (end of turn, /reload) are on ReqAbs below.

  // next-start! + (with-holder :turn ...): the idle tick starts turn n+1.
  pure def sesStartTurn(x: Session, y: Session): bool = and {
    canStartTurn(x),
    y == startTurn(x),
  }

  // A prompt typed at idle: offer! with :turn 0, then the idle tick starts it
  // (offer then startTurn, fused for models that do not split them). q is a
  // fresh seq, or UNTRACKED_LINE for a model without a mailbox.
  pure def sesPromptTurn(x: Session, y: Session, q: int): bool = and {
    x.kind == "none",
    not(x.start),
    y == startTurn(offer(x, q, 0, false)),
  }

  // A seq never admitted: no disposition and not queued.
  pure def freshSeq(x: Session, q: int): bool =
    x.why.get(q) == "" and not(x.steer.contains(q)) and not(x.followUp.contains(q))

  // offer! of fresh seq q: t = -1 local, 0 idle-only start, t > 0 steer turn t.
  // Turn numbers other than 0 and n behave alike (refused), so n + 1 stands for them.
  pure def sesOffer(x: Session, y: Session): bool =
    SEQS.exists(q => and {
      freshSeq(x, q),
      Set(-1, 0, x.n, x.n + 1).exists(t => Bool.exists(f => y == offer(x, q, t, f))),
    })

  // take! :steer at a boundary of the running, unparked turn.
  pure def sesTakeSteer(x: Session, y: Session, parked: int): bool = and {
    x.kind == "turn", parked < 0, x.steer != Set(),
    y == takeSteer(x),
  }

  // take! :follow-up at a natural stop: steering wins.
  pure def sesTakeFollowUp(x: Session, y: Session, parked: int): bool = and {
    x.kind == "turn", parked < 0, x.steer == Set(), x.followUp != Set(),
    y == takeFollowUp(x),
  }

  // request-job! / next-job! / the job's release, for an exclusive job
  // (/reload, /handoff, compaction). next-job! starts one only when idle with
  // no turn start pending (turns first).
  pure def canStartExclusive(x: Session): bool = and {
    x.kind == "none",
    not(x.start and x.followUp != Set()),
  }

  pure def sesStartExclusive(x: Session, y: Session): bool = and {
    canStartExclusive(x), x.exReq,
    y == startExclusive(x),
  }

  // No request is parked outside a turn, so an exclusive release resolves nothing.
  pure def sesEndExclusive(x: Session, y: Session): bool = and {
    x.kind == "exclusive",
    y == release(x),
  }

  pure def sessionStep(x: Session, y: Session, parked: int): bool = or {
    sesStartTurn(x, y),
    sesPromptTurn(x, y, UNTRACKED_LINE),
    SEQS.exists(q => freshSeq(x, q) and sesPromptTurn(x, y, q)),
    sesOffer(x, y),
    sesTakeSteer(x, y, parked),
    sesTakeFollowUp(x, y, parked),
    // cancel! of the current holder (one aimed at another hid is a no-op)
    y == cancelHolder(x, x.hid),
    Set("steer", "followUp").exists(w => MODES.exists(m => y == setMode(x, w, m))),
    // explicit clears (/new, /resume, /queue clear)
    y == clearSteer(x),
    y == clearFollowUp(x),
    y == requestExclusive(x),
    sesStartExclusive(x, y),
    sesEndExclusive(x, y),
  }

  pure def sameRequests(a: ReqAbs, b: ReqAbs): bool = and {
    b.parkedOn == a.parkedOn, b.gen == a.gen, b.hasResolver == a.hasResolver,
    b.rScope == a.rScope, b.rGen == a.rGen, b.rVer == a.rVer,
    b.rStatus == a.rStatus, b.rRes == a.rRes, b.rRem == a.rRem,
  }

  // The turn's body exits (natural end or cancel): with-holder releases the
  // session, handing back unread steer lines, and the turn's own pending
  // requests resolve "ended" in the same step.
  pure def absEndTurn(a: ReqAbs, b: ReqAbs): bool =
    val own = pendingSet(a).filter(i => a.rScope.get(i) == a.ses.n)
    val resolved = resolveSet(a, own, "ended")
    and {
      inTurn(a),
      b == { ...resolved, ses: release(a.ses), parkedOn: -1 },
    }

  // ---- /reload: an exclusive job ----

  // /reload's effect, inside its exclusive job: idle-scoped requests resolve
  // "cancelled" and the generation advances. Turn-scoped requests cannot
  // straddle it: no turn holds the session while the job does.
  pure def reloadEffect(a: ReqAbs): ReqAbs =
    val idleP = pendingSet(a).filter(i => a.rScope.get(i) == 0)
    { ...resolveSet(a, idleP, "cancelled"), gen: a.gen + 1 }

  pure def absReload(a: ReqAbs, b: ReqAbs): bool = and {
    a.ses.kind == "exclusive",
    b == reloadEffect(a),
  }

  // The whole /reload job in one step, for models that do not split the
  // holder: startExclusive; reload; release.
  pure def absReloadJob(a: ReqAbs, b: ReqAbs): bool =
    val held = { ...a, ses: startExclusive(a.ses) }
    and {
      canStartExclusive(a.ses),
      b == { ...reloadEffect(held), ses: release(held.ses) },
    }

  // ---- request steps ----

  pure def absOpenReq(a: ReqAbs, b: ReqAbs, i: int, scope: int, bgt: int): bool = and {
    IDS.contains(i),
    a.rStatus.get(i) == "none",
    bgt >= 1,
    if (scope > 0) (inTurn(a) and a.parkedOn < 0 and scope == a.ses.n)
    else (not(inTurn(a)) and pendingSet(a).forall(j => a.rScope.get(j) != 0)),
    if (a.hasResolver)
      b == {
        ...a,
        parkedOn: if (scope > 0) i else a.parkedOn,
        rScope: a.rScope.set(i, scope),
        rGen: a.rGen.set(i, a.gen),
        rVer: a.rVer.set(i, 0),
        rStatus: a.rStatus.set(i, "pending"),
        rRes: a.rRes.set(i, 0),
        rRem: a.rRem.set(i, bgt),
      }
    else
      b == {
        ...a,
        rScope: a.rScope.set(i, scope),
        rGen: a.rGen.set(i, a.gen),
        rVer: a.rVer.set(i, 0),
        rStatus: a.rStatus.set(i, "timeout"),
        rRes: a.rRes.set(i, 1),
        rRem: a.rRem.set(i, 0),
      },
  }

  pure def absUpdateChoices(a: ReqAbs, b: ReqAbs, i: int): bool = and {
    IDS.contains(i),
    a.rStatus.get(i) == "pending",
    a.rScope.get(i) == 0,
    b == { ...a, rVer: a.rVer.set(i, a.rVer.get(i) + 1) },
  }

  pure def absAnswer(a: ReqAbs, b: ReqAbs, i: int): bool = and {
    IDS.contains(i),
    a.rStatus.get(i) == "pending",
    a.hasResolver,
    if (a.rScope.get(i) > 0) and {
      inTurn(a),
      a.parkedOn == i,
      b == { ...resolveSet(a, Set(i), "answered"), parkedOn: -1 },
    } else if (inTurn(a))
      b == resolveSet(a, Set(i), "aborted")
    else
      b == resolveSet(a, Set(i), "answered"),
  }

  pure def absTickOrTimeout(a: ReqAbs, b: ReqAbs, i: int): bool = and {
    IDS.contains(i),
    a.rStatus.get(i) == "pending",
    or {
      and {
        a.rRem.get(i) > 1,
        b == { ...a, rRem: a.rRem.set(i, a.rRem.get(i) - 1) },
      },
      b == {
        ...resolveSet(a, Set(i), "timeout"),
        parkedOn: if (a.parkedOn == i) -1 else a.parkedOn,
      },
    },
  }

  pure def absSetResolver(a: ReqAbs, b: ReqAbs, hasRes: bool): bool =
    val P = pendingSet(a)
    or {
      b == { ...a, hasResolver: hasRes },
      and {
        not(hasRes),
        b == { ...resolveSet(a, P, "timeout"), hasResolver: false, parkedOn: -1 },
      },
    }

  // Session steps: a move of the holder with the request table unchanged,
  // or one that composes request resolution (end of turn, a whole /reload job).
  pure def sessionNext(a: ReqAbs, b: ReqAbs): bool = or {
    absEndTurn(a, b),
    absReloadJob(a, b),
    and { sameRequests(a, b), sessionStep(a.ses, b.ses, a.parkedOn) },
  }

  // Request steps (and /reload inside its job): the session is unchanged.
  pure def requestNext(a: ReqAbs, b: ReqAbs): bool = and {
    b.ses == a.ses,
    or {
      absReload(a, b),
      absSetResolver(a, b, b.hasResolver),
      IDS.exists(i => or {
        absOpenReq(a, b, i, b.rScope.get(i), if (b.rRem.get(i) > 0) b.rRem.get(i) else 1),
        absUpdateChoices(a, b, i),
        absAnswer(a, b, i),
        absTickOrTimeout(a, b, i),
      }),
    },
  }

  pure def reqAbsNext(a: ReqAbs, b: ReqAbs): bool = or {
    a == b,
    if (b.ses == a.ses) requestNext(a, b) else sessionNext(a, b),
  }

  pure def resolvedOnce(a: ReqAbs): bool =
    IDS.forall(i =>
      a.rRes.get(i) == (if (RESOLVED_STATUSES.contains(a.rStatus.get(i))) 1 else 0))

  pure def noOrphanTurnReq(a: ReqAbs): bool =
    IDS.forall(i =>
      a.rStatus.get(i) != "pending"
        or a.rScope.get(i) == 0
        or (inTurn(a) and a.rScope.get(i) == a.ses.n))

  pure def parkConsistent(a: ReqAbs): bool = and {
    a.parkedOn >= 0 implies (
      inTurn(a) and IDS.contains(a.parkedOn)
        and a.rStatus.get(a.parkedOn) == "pending"
        and a.rScope.get(a.parkedOn) == a.ses.n
    ),
    IDS.forall(i =>
      (a.rStatus.get(i) == "pending" and a.rScope.get(i) > 0)
        implies a.parkedOn == i),
  }

  pure def pendingCurrentGen(a: ReqAbs): bool =
    IDS.forall(i =>
      a.rStatus.get(i) == "pending" implies a.rGen.get(i) == a.gen)

  pure def pendingBoundedBudget(a: ReqAbs): bool =
    IDS.forall(i =>
      if (a.rStatus.get(i) == "pending") a.rRem.get(i) >= 1 else a.rRem.get(i) == 0)

  // The mailbox invariants (steer lines only for the running turn, queued
  // lines undisposed, ...) are the holder's, proved in proofs/holder.
  pure def reqAbsInv(a: ReqAbs): bool = and {
    sessionInv(a.ses),
    resolvedOnce(a),
    noOrphanTurnReq(a),
    parkConsistent(a),
    pendingCurrentGen(a),
    pendingBoundedBudget(a),
  }
}
