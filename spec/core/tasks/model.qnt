// The abstract task table (#671) and async-request ownership (#397, #398) machines,
// checked on their own:
// - `tasksSpec`: task slot lifecycle, xpcall fault isolation, cancel arms, and poll cadence.
// - `requestsSpec`: turn-keyed steering, request scopes, reload generation, and countdown tick budgets.
//
// Both machines' invariants are proved inductively (`verify.tsv: inductive`), so every
// concrete model that refines them inherits their invariants at any depth.
module tasksSpec {
  import tasksAbstract.* from "./abstract"

  pure val OWNERS = Set(1, 2)
  pure val TIDS = Set(1, 2)

  pure val SLOT_STATES: Set[{ status: str, owner: int, cancel: bool, armed: bool }] =
    Set({ status: "none", owner: 0, cancel: false, armed: false })
    .union(
      OWNERS.map(o => Bool.map(c => Bool.map(arm =>
        { status: "ready", owner: o, cancel: c, armed: arm }
      )).flatten()).flatten()
    )
    .union(
      OWNERS.map(o => Bool.map(c =>
        { status: "done", owner: o, cancel: c, armed: false }
      )).flatten()
    )

  pure val ABS_STATES: Set[Abs] =
    SLOT_STATES.map(s1 => SLOT_STATES.map(s2 => Bool.map(fc =>
      val runnable = (s1.status == "ready" or s2.status == "ready")
      { t1Status: s1.status, t1Owner: s1.owner, t1Cancel: s1.cancel, t1Armed: s1.armed,
        t2Status: s2.status, t2Owner: s2.owner, t2Cancel: s2.cancel, t2Armed: s2.armed,
        anyRunnable: runnable, pollActive: runnable, faultCaught: fc }
    )).flatten()).flatten()

  var a: Abs
  var prev: Abs // ghost: state before the last step

  action init = all { a' = absInit, prev' = absInit }

  action move(b: Abs): bool = all { a' = b, prev' = a }

  action doSpawn(tid: int, owner: int): bool =
    if (tid == 1)
      all {
        a.t1Status == "none",
        move({ ...a, t1Status: "ready", t1Owner: owner, t1Cancel: false, t1Armed: false,
               anyRunnable: true, pollActive: true, faultCaught: false }),
      }
    else
      all {
        a.t2Status == "none",
        move({ ...a, t2Status: "ready", t2Owner: owner, t2Cancel: false, t2Armed: false,
               anyRunnable: true, pollActive: true, faultCaught: false }),
      }

  action doRequestCancel(owner: int): bool = any {
    all {
      a.t1Owner == owner, a.t1Status != "none",
      move({ ...a, t1Cancel: true, faultCaught: false }),
    },
    all {
      a.t2Owner == owner, a.t2Status != "none",
      move({ ...a, t2Cancel: true, faultCaught: false }),
    },
  }

  action doArmCancel(owner: int): bool = any {
    all {
      a.t1Owner == owner, a.t1Status == "ready",
      move({ ...a, t1Armed: true, faultCaught: false }),
    },
    all {
      a.t2Owner == owner, a.t2Status == "ready",
      move({ ...a, t2Armed: true, faultCaught: false }),
    },
  }

  action doDriverStepNormal(tid: int, completes: bool): bool =
    if (tid == 1)
      all {
        a.t1Status == "ready",
        val nextSt = if (completes) "done" else "ready"
        val nextArmed = if (completes) false else a.t1Armed
        val runnable = (nextSt == "ready" or a.t2Status == "ready")
        move({ ...a, t1Status: nextSt, t1Armed: nextArmed,
               anyRunnable: runnable, pollActive: runnable, faultCaught: false }),
      }
    else
      all {
        a.t2Status == "ready",
        val nextSt = if (completes) "done" else "ready"
        val nextArmed = if (completes) false else a.t2Armed
        val runnable = (a.t1Status == "ready" or nextSt == "ready")
        move({ ...a, t2Status: nextSt, t2Armed: nextArmed,
               anyRunnable: runnable, pollActive: runnable, faultCaught: false }),
      }

  action doDriverStepFault(tid: int): bool =
    if (tid == 1)
      all {
        a.t1Status == "ready",
        val runnable = (a.t2Status == "ready")
        move({ ...a, t1Status: "done", t1Armed: false,
               anyRunnable: runnable, pollActive: runnable, faultCaught: true }),
      }
    else
      all {
        a.t2Status == "ready",
        val runnable = (a.t1Status == "ready")
        move({ ...a, t2Status: "done", t2Armed: false,
               anyRunnable: runnable, pollActive: runnable, faultCaught: true }),
      }

  action doRetire(tid: int): bool =
    if (tid == 1)
      all {
        a.t1Status == "done",
        val runnable = (a.t2Status == "ready")
        move({ ...a, t1Status: "none", t1Owner: 0, t1Cancel: false, t1Armed: false,
               anyRunnable: runnable, pollActive: runnable, faultCaught: false }),
      }
    else
      all {
        a.t2Status == "done",
        val runnable = (a.t1Status == "ready")
        move({ ...a, t2Status: "none", t2Owner: 0, t2Cancel: false, t2Armed: false,
               anyRunnable: runnable, pollActive: runnable, faultCaught: false }),
      }

  action step = any {
    nondet tid = TIDS.oneOf()
    nondet o = OWNERS.oneOf()
    doSpawn(tid, o),
    nondet o = OWNERS.oneOf()
    doRequestCancel(o),
    nondet o = OWNERS.oneOf()
    doArmCancel(o),
    nondet tid = TIDS.oneOf()
    nondet comp = Bool.oneOf()
    doDriverStepNormal(tid, comp),
    nondet tid = TIDS.oneOf()
    doDriverStepFault(tid),
    nondet tid = TIDS.oneOf()
    doRetire(tid),
  }

  // ---- properties ----

  val movesAreAbsSteps = absNext(prev, a)

  val ownershipIsolatedInv = ownershipIsolated(a)
  val cadenceMatchesRunnableInv = cadenceMatchesRunnable(a)
  val runnableConsistencyInv = runnableConsistency(a)
  val cancelRequiresRegisteredInv = cancelRequiresRegistered(a)

  val inductiveInv = and {
    a.in(ABS_STATES),
    prev.in(ABS_STATES),
    absInv(a),
  }

  val allInvariants = and {
    movesAreAbsSteps,
    ownershipIsolatedInv,
    cadenceMatchesRunnableInv,
    runnableConsistencyInv,
    cancelRequiresRegisteredInv,
    inductiveInv,
  }
}

module requestsSpec {
  import requestsAbstract.* from "./abstract"

  pure val MAX_TURNS = 2
  pure val MAX_GEN = 2
  pure val MAX_VER = 1
  pure val MAX_BUDGET = 2
  pure val TURNS = 0.to(MAX_TURNS)
  pure val GENS = 0.to(MAX_GEN)
  pure val VERS = 0.to(MAX_VER)
  pure val REMS = 0.to(MAX_BUDGET)
  pure val PARKS = Set(-1).union(IDS)

  var running: bool
  var turnNo: int
  var parkedOn: int
  var gen: int
  var hasResolver: bool
  var queue: Set[int]
  var rScope: int -> int
  var rGen: int -> int
  var rVer: int -> int
  var rStatus: int -> str
  var rRes: int -> int
  var rRem: int -> int
  var ticksSinceOpen: int -> int

  // Ghost sticky monitor: stays true iff every transition taken so far
  // satisfied `reqAbsNext(toAbs, b)`.
  var stepOk: bool

  def toAbs: ReqAbs = {
    running: running,
    turnNo: turnNo,
    parkedOn: parkedOn,
    gen: gen,
    hasResolver: hasResolver,
    queue: queue,
    rScope: rScope,
    rGen: rGen,
    rVer: rVer,
    rStatus: rStatus,
    rRes: rRes,
    rRem: rRem,
  }

  action fromAbs(b: ReqAbs, tso: int -> int): bool = all {
    running' = b.running,
    turnNo' = b.turnNo,
    parkedOn' = b.parkedOn,
    gen' = b.gen,
    hasResolver' = b.hasResolver,
    queue' = b.queue,
    rScope' = b.rScope,
    rGen' = b.rGen,
    rVer' = b.rVer,
    rStatus' = b.rStatus,
    rRes' = b.rRes,
    rRem' = b.rRem,
    ticksSinceOpen' = tso,
    stepOk' = (stepOk and reqAbsNext(toAbs, b)),
  }

  action init =
    val a0 = reqAbsInit(true)
    all {
      running' = a0.running,
      turnNo' = a0.turnNo,
      parkedOn' = a0.parkedOn,
      gen' = a0.gen,
      hasResolver' = a0.hasResolver,
      queue' = a0.queue,
      rScope' = a0.rScope,
      rGen' = a0.rGen,
      rVer' = a0.rVer,
      rStatus' = a0.rStatus,
      rRes' = a0.rRes,
      rRem' = a0.rRem,
      ticksSinceOpen' = IDS.mapBy(_i => 0),
      stepOk' = true,
    }

  action doStartTurn: bool =
    val a = toAbs
    all {
      not(a.running),
      a.turnNo < MAX_TURNS,
      fromAbs({ ...a, running: true, turnNo: a.turnNo + 1, parkedOn: -1 }, ticksSinceOpen),
    }

  action doEndTurn: bool =
    val a = toAbs
    val own = pendingSet(a).filter(i => a.rScope.get(i) == a.turnNo)
    val resolved = resolveSet(a, own, "ended")
    all {
      a.running,
      fromAbs(
        { ...resolved, running: false, parkedOn: -1, queue: Set() },
        IDS.mapBy(i => if (own.contains(i)) 0 else ticksSinceOpen.get(i))
      ),
    }

  action doQueueSteer: bool =
    val a = toAbs
    all {
      a.running,
      fromAbs({ ...a, queue: a.queue.union(Set(a.turnNo)) }, ticksSinceOpen),
    }

  action doInjectSteer: bool =
    val a = toAbs
    all {
      a.running,
      a.parkedOn < 0,
      a.queue.contains(a.turnNo),
      fromAbs({ ...a, queue: Set() }, ticksSinceOpen),
    }

  action doOpenReq(i: int, tool: bool, bgt: int): bool =
    val a = toAbs
    val scope = if (tool) a.turnNo else 0
    all {
      IDS.contains(i),
      a.rStatus.get(i) == "none",
      1 <= bgt, bgt <= MAX_BUDGET,
      if (tool) (a.running and a.parkedOn < 0)
      else (not(a.running) and pendingSet(a).forall(j => a.rScope.get(j) != 0)),
      if (a.hasResolver)
        fromAbs(
          {
            ...a,
            parkedOn: if (tool) i else a.parkedOn,
            rScope: a.rScope.set(i, scope),
            rGen: a.rGen.set(i, a.gen),
            rVer: a.rVer.set(i, 0),
            rStatus: a.rStatus.set(i, "pending"),
            rRes: a.rRes.set(i, 0),
            rRem: a.rRem.set(i, bgt),
          },
          ticksSinceOpen.set(i, 0)
        )
      else
        fromAbs(
          {
            ...a,
            rScope: a.rScope.set(i, scope),
            rGen: a.rGen.set(i, a.gen),
            rVer: a.rVer.set(i, 0),
            rStatus: a.rStatus.set(i, "timeout"),
            rRes: a.rRes.set(i, 1),
            rRem: a.rRem.set(i, 0),
          },
          ticksSinceOpen.set(i, 0)
        ),
    }

  action doUpdateChoices(i: int): bool =
    val a = toAbs
    all {
      IDS.contains(i),
      a.rStatus.get(i) == "pending",
      a.rScope.get(i) == 0,
      a.rVer.get(i) < MAX_VER,
      fromAbs({ ...a, rVer: a.rVer.set(i, a.rVer.get(i) + 1) }, ticksSinceOpen),
    }

  action doAnswer(i: int): bool =
    val a = toAbs
    all {
      IDS.contains(i),
      a.rStatus.get(i) == "pending",
      a.hasResolver,
      if (a.rScope.get(i) > 0) all {
        a.running,
        a.parkedOn == i,
        fromAbs(
          { ...resolveSet(a, Set(i), "answered"), parkedOn: -1 },
          ticksSinceOpen.set(i, 0)
        ),
      } else if (a.running)
        fromAbs(
          resolveSet(a, Set(i), "aborted"),
          ticksSinceOpen.set(i, 0)
        )
      else
        fromAbs(
          resolveSet(a, Set(i), "answered"),
          ticksSinceOpen.set(i, 0)
        ),
    }

  action doTick(i: int): bool =
    val a = toAbs
    all {
      IDS.contains(i),
      a.rStatus.get(i) == "pending",
      if (a.rRem.get(i) > 1)
        fromAbs(
          { ...a, rRem: a.rRem.set(i, a.rRem.get(i) - 1) },
          ticksSinceOpen.set(i, ticksSinceOpen.get(i) + 1)
        )
      else
        fromAbs(
          {
            ...resolveSet(a, Set(i), "timeout"),
            parkedOn: if (a.parkedOn == i) -1 else a.parkedOn,
          },
          ticksSinceOpen.set(i, 0)
        ),
    }

  action doReload: bool =
    val a = toAbs
    val idleP = pendingSet(a).filter(i => a.rScope.get(i) == 0)
    all {
      not(a.running),
      a.gen < MAX_GEN,
      fromAbs(
        { ...resolveSet(a, idleP, "cancelled"), gen: a.gen + 1 },
        IDS.mapBy(i => if (idleP.contains(i)) 0 else ticksSinceOpen.get(i))
      ),
    }

  action doSetResolver(hr: bool): bool =
    val a = toAbs
    fromAbs({ ...a, hasResolver: hr }, ticksSinceOpen)

  action step = {
    nondet i = IDS.oneOf()
    nondet tool = Bool.oneOf()
    nondet bgt = 1.to(MAX_BUDGET).oneOf()
    nondet hr = Bool.oneOf()
    any {
      doStartTurn,
      doEndTurn,
      doQueueSteer,
      doInjectSteer,
      doOpenReq(i, tool, bgt),
      doUpdateChoices(i),
      doAnswer(i),
      doTick(i),
      doReload,
      doSetResolver(hr),
    }
  }

  // ---- Properties ----

  val movesAreAbsSteps = stepOk
  val resolvedOnceInv = resolvedOnce(toAbs)
  val noOrphanTurnReqInv = noOrphanTurnReq(toAbs)
  val parkConsistentInv = parkConsistent(toAbs)
  val pendingCurrentGenInv = pendingCurrentGen(toAbs)
  val queueOwnedByRunningTurnInv = queueOwnedByRunningTurn(toAbs)
  val pendingBoundedBudgetInv = pendingBoundedBudget(toAbs)

  val boundedWaitTicksInv = IDS.forall(i =>
    rStatus.get(i) == "pending"
      implies (ticksSinceOpen.get(i) >= 0 and rRem.get(i) + ticksSinceOpen.get(i) <= MAX_BUDGET))

  val allInvariants = and {
    movesAreAbsSteps,
    resolvedOnceInv,
    noOrphanTurnReqInv,
    parkConsistentInv,
    pendingCurrentGenInv,
    queueOwnedByRunningTurnInv,
    pendingBoundedBudgetInv,
    boundedWaitTicksInv,
  }

  val inductiveInv = and {
    running.in(Bool),
    turnNo.in(TURNS),
    parkedOn.in(PARKS),
    gen.in(GENS),
    hasResolver.in(Bool),
    queue.in(powerset(TURNS)),
    rScope.in(setOfMaps(IDS, TURNS)),
    rGen.in(setOfMaps(IDS, GENS)),
    rVer.in(setOfMaps(IDS, VERS)),
    rStatus.in(setOfMaps(IDS, STATUSES)),
    rRes.in(setOfMaps(IDS, 0.to(1))),
    rRem.in(setOfMaps(IDS, REMS)),
    ticksSinceOpen.in(setOfMaps(IDS, REMS)),
    stepOk.in(Bool),
    running implies turnNo >= 1,
    IDS.forall(i => rScope.get(i) <= turnNo),
    IDS.forall(i => rGen.get(i) <= gen),
    IDS.forall(i => rStatus.get(i) != "pending" implies ticksSinceOpen.get(i) == 0),
    allInvariants,
  }
}
