// The abstract task table (#671) and async-request ownership (#397, #398) machines,
// checked on their own:
// - `tasksSpec`: task slot lifecycle, xpcall fault isolation, cancel arms, and poll cadence.
// - `requestsSpec`: the session holder (proofs/holder) composed with request scopes,
//   /reload as an exclusive job with a generation, and countdown tick budgets.
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
  import holderAbstract.* from "./proofs/holder/model"

  pure val MAX_TURNS = 2
  pure val MAX_GEN = 2
  pure val MAX_VER = 1
  pure val MAX_BUDGET = 2
  pure val MAX_HID = 4
  pure val TURNS = 0.to(MAX_TURNS)
  pure val HIDS = 0.to(MAX_HID)
  pure val GENS = 0.to(MAX_GEN)
  pure val VERS = 0.to(MAX_VER)
  pure val REMS = 0.to(MAX_BUDGET)
  pure val PARKS = Set(-1).union(IDS)

  // The session holder (`holderAbstract::Session`), split into variables so
  // Apalache can bound each one.
  var kind: str
  var n: int
  var hid: int
  var steer: Set[int]
  var followUp: Set[int]
  var start: bool
  var firstUp: int
  var exReq: bool
  var cancel: bool
  var steerMode: str
  var followMode: str
  var why: int -> str
  var whyN: int -> int

  def ses: Session = {
    kind: kind, n: n, hid: hid, steer: steer, followUp: followUp, start: start,
    firstUp: firstUp, exReq: exReq, cancel: cancel, steerMode: steerMode,
    followMode: followMode, why: why, whyN: whyN,
  }

  var nextSeq: int
  // Ghosts: lines offered without :turn (Enter, an extension), and whether a
  // follow-up was ever taken while steer lines waited.
  var isLocal: int -> bool
  var orderOk: bool

  var parkedOn: int
  var gen: int
  var hasResolver: bool
  var rScope: int -> int
  var rGen: int -> int
  var rVer: int -> int
  var rStatus: int -> str
  var rRes: int -> int
  var rRem: int -> int
  var ticksSinceOpen: int -> int

  // The previous state, copied each step. Refinement is a state predicate
  // over (previous, current), so the step relation carries no reqAbsNext and
  // the base induction stays cheap; only the refinement proof pays for it
  // (the holder proofs' layout).
  var pKind: str
  var pN: int
  var pHid: int
  var pSteer: Set[int]
  var pFollowUp: Set[int]
  var pStart: bool
  var pFirstUp: int
  var pExReq: bool
  var pCancel: bool
  var pSteerMode: str
  var pFollowMode: str
  var pWhy: int -> str
  var pWhyN: int -> int
  var pParkedOn: int
  var pGen: int
  var pHasResolver: bool
  var pRScope: int -> int
  var pRGen: int -> int
  var pRVer: int -> int
  var pRStatus: int -> str
  var pRRes: int -> int
  var pRRem: int -> int

  def prevAbs: ReqAbs = {
    ses: { kind: pKind, n: pN, hid: pHid, steer: pSteer, followUp: pFollowUp, start: pStart, firstUp: pFirstUp, exReq: pExReq, cancel: pCancel, steerMode: pSteerMode, followMode: pFollowMode, why: pWhy, whyN: pWhyN },
    parkedOn: pParkedOn, gen: pGen, hasResolver: pHasResolver, rScope: pRScope, rGen: pRGen,
    rVer: pRVer, rStatus: pRStatus, rRes: pRRes, rRem: pRRem,
  }

  def toAbs: ReqAbs = {
    ses: ses,
    parkedOn: parkedOn,
    gen: gen,
    hasResolver: hasResolver,
    rScope: rScope,
    rGen: rGen,
    rVer: rVer,
    rStatus: rStatus,
    rRes: rRes,
    rRem: rRem,
  }

  action fromAbs(b: ReqAbs, tso: int -> int): bool = fromAbsG(b, tso, nextSeq, isLocal, orderOk)

  action fromAbsG(b: ReqAbs, tso: int -> int, nSeq: int, nLocal: int -> bool, nOrder: bool): bool = all {
    kind' = b.ses.kind,
    n' = b.ses.n,
    hid' = b.ses.hid,
    steer' = b.ses.steer,
    followUp' = b.ses.followUp,
    start' = b.ses.start,
    firstUp' = b.ses.firstUp,
    exReq' = b.ses.exReq,
    cancel' = b.ses.cancel,
    steerMode' = b.ses.steerMode,
    followMode' = b.ses.followMode,
    why' = b.ses.why,
    whyN' = b.ses.whyN,
    nextSeq' = nSeq,
    isLocal' = nLocal,
    orderOk' = nOrder,
    parkedOn' = b.parkedOn,
    gen' = b.gen,
    hasResolver' = b.hasResolver,
    rScope' = b.rScope,
    rGen' = b.rGen,
    rVer' = b.rVer,
    rStatus' = b.rStatus,
    rRes' = b.rRes,
    rRem' = b.rRem,
    ticksSinceOpen' = tso,
    pKind' = kind,
    pN' = n,
    pHid' = hid,
    pSteer' = steer,
    pFollowUp' = followUp,
    pStart' = start,
    pFirstUp' = firstUp,
    pExReq' = exReq,
    pCancel' = cancel,
    pSteerMode' = steerMode,
    pFollowMode' = followMode,
    pWhy' = why,
    pWhyN' = whyN,
    pParkedOn' = parkedOn,
    pGen' = gen,
    pHasResolver' = hasResolver,
    pRScope' = rScope,
    pRGen' = rGen,
    pRVer' = rVer,
    pRStatus' = rStatus,
    pRRes' = rRes,
    pRRem' = rRem,
  }

  action init =
    val a0 = reqAbsInit(true)
    all {
      kind' = a0.ses.kind,
      n' = a0.ses.n,
      hid' = a0.ses.hid,
      steer' = a0.ses.steer,
      followUp' = a0.ses.followUp,
      start' = a0.ses.start,
      firstUp' = a0.ses.firstUp,
      exReq' = a0.ses.exReq,
      cancel' = a0.ses.cancel,
      steerMode' = a0.ses.steerMode,
      followMode' = a0.ses.followMode,
      why' = a0.ses.why,
      whyN' = a0.ses.whyN,
      nextSeq' = 0,
      isLocal' = SEQS.mapBy(_q => false),
      orderOk' = true,
      parkedOn' = a0.parkedOn,
      gen' = a0.gen,
      hasResolver' = a0.hasResolver,
      rScope' = a0.rScope,
      rGen' = a0.rGen,
      rVer' = a0.rVer,
      rStatus' = a0.rStatus,
      rRes' = a0.rRes,
      rRem' = a0.rRem,
      ticksSinceOpen' = IDS.mapBy(_i => 0),
      pKind' = a0.ses.kind,
      pN' = a0.ses.n,
      pHid' = a0.ses.hid,
      pSteer' = a0.ses.steer,
      pFollowUp' = a0.ses.followUp,
      pStart' = a0.ses.start,
      pFirstUp' = a0.ses.firstUp,
      pExReq' = a0.ses.exReq,
      pCancel' = a0.ses.cancel,
      pSteerMode' = a0.ses.steerMode,
      pFollowMode' = a0.ses.followMode,
      pWhy' = a0.ses.why,
      pWhyN' = a0.ses.whyN,
      pParkedOn' = a0.parkedOn,
      pGen' = a0.gen,
      pHasResolver' = a0.hasResolver,
      pRScope' = a0.rScope,
      pRGen' = a0.rGen,
      pRVer' = a0.rVer,
      pRStatus' = a0.rStatus,
      pRRes' = a0.rRes,
      pRRem' = a0.rRem,
    }

  // ---- the session (holderAbstract steps) ----

  // offer! text {:turn t :follow-up? f}; t = -1: no :turn (Enter, an
  // extension), so busy-time input behind /reload or /handoff waits as a
  // follow-up instead of being refused.
  action doOffer(t: int, f: bool): bool =
    val a = toAbs
    val q = nextSeq
    all {
      nextSeq < MAX_SEQ,
      fromAbsG({ ...a, ses: offer(a.ses, q, t, f) }, ticksSinceOpen,
               nextSeq + 1, isLocal.set(q, t == -1), orderOk),
    }

  // next-start! + (with-holder :turn ...) at the driver's idle tick.
  action doStartTurn: bool =
    val a = toAbs
    all {
      canStartTurn(a.ses),
      a.ses.n < MAX_TURNS,
      a.ses.hid < MAX_HID,
      fromAbs({ ...a, ses: startTurn(a.ses), parkedOn: -1 }, ticksSinceOpen),
    }

  // The turn's body exits (natural end or cancel): release, and the turn's
  // pending requests resolve "ended".
  action doEndTurn: bool =
    val a = toAbs
    val own = pendingSet(a).filter(i => a.rScope.get(i) == a.ses.n)
    val resolved = resolveSet(a, own, "ended")
    all {
      a.ses.kind == "turn",
      fromAbs(
        { ...resolved, ses: release(a.ses), parkedOn: -1 },
        IDS.mapBy(i => if (own.contains(i)) 0 else ticksSinceOpen.get(i))
      ),
    }

  action doTakeSteer: bool =
    val a = toAbs
    all {
      a.ses.kind == "turn",
      a.parkedOn < 0,
      a.ses.steer != Set(),
      fromAbs({ ...a, ses: takeSteer(a.ses) }, ticksSinceOpen),
    }

  action doTakeFollowUp: bool =
    val a = toAbs
    all {
      a.ses.kind == "turn",
      a.parkedOn < 0,
      a.ses.steer == Set(),
      a.ses.followUp != Set(),
      fromAbsG({ ...a, ses: takeFollowUp(a.ses) }, ticksSinceOpen,
               nextSeq, isLocal, (orderOk and a.ses.steer == Set())),
    }

  action doCancel: bool =
    val a = toAbs
    fromAbs({ ...a, ses: cancelHolder(a.ses, a.ses.hid) }, ticksSinceOpen)

  action doSetMode(w: str, m: str): bool =
    val a = toAbs
    fromAbs({ ...a, ses: setMode(a.ses, w, m) }, ticksSinceOpen)

  action doClearSteer: bool =
    val a = toAbs
    fromAbs({ ...a, ses: clearSteer(a.ses) }, ticksSinceOpen)

  action doClearFollowUp: bool =
    val a = toAbs
    fromAbs({ ...a, ses: clearFollowUp(a.ses) }, ticksSinceOpen)

  // ---- exclusive jobs: /reload (and /handoff, compaction) ----

  // request-job!: /reload (typed, or an agent's reload request) asks the scheduler.
  action doRequestReload: bool =
    val a = toAbs
    all { not(a.ses.exReq), fromAbs({ ...a, ses: requestExclusive(a.ses) }, ticksSinceOpen) }

  // next-job!: idle, no turn start pending.
  action doStartExclusive: bool =
    val a = toAbs
    all {
      canStartExclusive(a.ses),
      a.ses.exReq,
      a.ses.hid < MAX_HID,
      fromAbs({ ...a, ses: startExclusive(a.ses) }, ticksSinceOpen),
    }

  // The /reload body: idle-scoped requests resolve "cancelled"; generation advances.
  action doReload: bool =
    val a = toAbs
    val idleP = pendingSet(a).filter(i => a.rScope.get(i) == 0)
    all {
      a.ses.kind == "exclusive",
      a.gen < MAX_GEN,
      fromAbs(
        { ...resolveSet(a, idleP, "cancelled"), gen: a.gen + 1 },
        IDS.mapBy(i => if (idleP.contains(i)) 0 else ticksSinceOpen.get(i))
      ),
    }

  action doEndExclusive: bool =
    val a = toAbs
    all { a.ses.kind == "exclusive", fromAbs({ ...a, ses: release(a.ses) }, ticksSinceOpen) }

  // ---- requests ----

  action doOpenReq(i: int, tool: bool, bgt: int): bool =
    val a = toAbs
    val scope = if (tool) a.ses.n else 0
    all {
      IDS.contains(i),
      a.rStatus.get(i) == "none",
      1 <= bgt, bgt <= MAX_BUDGET,
      if (tool) (a.ses.kind == "turn" and a.parkedOn < 0)
      else (a.ses.kind != "turn" and pendingSet(a).forall(j => a.rScope.get(j) != 0)),
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
        a.ses.kind == "turn",
        a.parkedOn == i,
        fromAbs(
          { ...resolveSet(a, Set(i), "answered"), parkedOn: -1 },
          ticksSinceOpen.set(i, 0)
        ),
      } else if (a.ses.kind == "turn")
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

  action doSetResolver(hr: bool): bool =
    val a = toAbs
    fromAbs({ ...a, hasResolver: hr }, ticksSinceOpen)

  action step = {
    nondet i = IDS.oneOf()
    nondet tool = Bool.oneOf()
    nondet bgt = 1.to(MAX_BUDGET).oneOf()
    nondet hr = Bool.oneOf()
    nondet t = Set(-1, 0).union(1.to(MAX_TURNS)).oneOf()
    nondet w = Set("steer", "followUp").oneOf()
    nondet m = MODES.oneOf()
    any {
      doOffer(t, hr),
      doStartTurn,
      doEndTurn,
      doTakeSteer,
      doTakeFollowUp,
      doCancel,
      doSetMode(w, m),
      doClearSteer,
      doClearFollowUp,
      doRequestReload,
      doStartExclusive,
      doReload,
      doEndExclusive,
      doOpenReq(i, tool, bgt),
      doUpdateChoices(i),
      doAnswer(i),
      doTick(i),
      doSetResolver(hr),
    }
  }

  // ---- Properties ----

  // Refinement: the last step was a `reqAbsNext` step (or a stutter).
  val movesAreAbsSteps = reqAbsNext(prevAbs, toAbs)
  val sessionInvHolds = sessionInv(ses)
  val resolvedOnceInv = resolvedOnce(toAbs)
  val noOrphanTurnReqInv = noOrphanTurnReq(toAbs)
  val parkConsistentInv = parkConsistent(toAbs)
  val pendingCurrentGenInv = pendingCurrentGen(toAbs)
  val pendingBoundedBudgetInv = pendingBoundedBudget(toAbs)
  // No line lost: every admitted seq is still queued or has exactly one
  // disposition (taken, started, released, refused, cleared).
  val eachSeqOnceInv = SEQS.forall(q =>
    if (q < nextSeq)
      (steer.contains(q) or followUp.contains(q)) != (why.get(q) != "")
    else
      not(steer.contains(q)) and not(followUp.contains(q)) and why.get(q) == "")
  // FollowUpOrder: no follow-up was taken while the running turn had steering.
  val followUpOrderInv = orderOk
  // Busy-time input without :turn is never refused: it steers the open turn
  // or waits as a follow-up (the /reload and /handoff gap found in review).
  val localOfferNeverRefusedInv = SEQS.forall(q =>
    why.get(q) == "refused" implies not(isLocal.get(q)))

  val boundedWaitTicksInv = IDS.forall(i =>
    rStatus.get(i) == "pending"
      implies (ticksSinceOpen.get(i) >= 0 and rRem.get(i) + ticksSinceOpen.get(i) <= MAX_BUDGET))

  val safetyInvariants = and {
    sessionInvHolds,
    resolvedOnceInv,
    noOrphanTurnReqInv,
    parkConsistentInv,
    pendingCurrentGenInv,
    pendingBoundedBudgetInv,
    boundedWaitTicksInv,
    eachSeqOnceInv,
    followUpOrderInv,
    localOfferNeverRefusedInv,
  }

  // Simulation checks the refinement monitor too; the proofs split it off.
  val allInvariants = and { safetyInvariants, movesAreAbsSteps }

  val prevTyped = and {
    pKind.in(KINDS),
    pN.in(TURNS),
    pHid.in(HIDS),
    pSteer.in(powerset(SEQS)),
    pFollowUp.in(powerset(SEQS)),
    pStart.in(Bool),
    pFirstUp.in(Set(-1).union(SEQS)),
    pExReq.in(Bool),
    pCancel.in(Bool),
    pSteerMode.in(MODES),
    pFollowMode.in(MODES),
    pWhy.in(setOfMaps(SEQS, WHYS)),
    pWhyN.in(setOfMaps(SEQS, TURNS)),
    pParkedOn.in(PARKS),
    pGen.in(GENS),
    pHasResolver.in(Bool),
    pRScope.in(setOfMaps(IDS, TURNS)),
    pRGen.in(setOfMaps(IDS, GENS)),
    pRVer.in(setOfMaps(IDS, VERS)),
    pRStatus.in(setOfMaps(IDS, STATUSES)),
    pRRes.in(setOfMaps(IDS, 0.to(1))),
    pRRem.in(setOfMaps(IDS, REMS)),
  }

  val inductiveInv = and {
    prevTyped,
    kind.in(KINDS),
    n.in(TURNS),
    hid.in(HIDS),
    steer.in(powerset(SEQS)),
    followUp.in(powerset(SEQS)),
    start.in(Bool),
    firstUp.in(Set(-1).union(SEQS)),
    exReq.in(Bool),
    cancel.in(Bool),
    steerMode.in(MODES),
    followMode.in(MODES),
    why.in(setOfMaps(SEQS, WHYS)),
    whyN.in(setOfMaps(SEQS, TURNS)),
    nextSeq.in(0.to(MAX_SEQ)),
    isLocal.in(setOfMaps(SEQS, Bool)),
    orderOk.in(Bool),
    parkedOn.in(PARKS),
    gen.in(GENS),
    hasResolver.in(Bool),
    rScope.in(setOfMaps(IDS, TURNS)),
    rGen.in(setOfMaps(IDS, GENS)),
    rVer.in(setOfMaps(IDS, VERS)),
    rStatus.in(setOfMaps(IDS, STATUSES)),
    rRes.in(setOfMaps(IDS, 0.to(1))),
    rRem.in(setOfMaps(IDS, REMS)),
    ticksSinceOpen.in(setOfMaps(IDS, REMS)),
    n <= hid,
    start implies followUp != Set(),
    start implies kind != "turn",
    start == (firstUp >= 0),
    firstUp >= 0 implies followUp.contains(firstUp),
    SEQS.forall(q => whyN.get(q) <= n),
    SEQS.forall(q => q >= nextSeq implies (whyN.get(q) == 0 and not(isLocal.get(q)))),
    IDS.forall(i => rScope.get(i) <= n),
    IDS.forall(i => rGen.get(i) <= gen),
    IDS.forall(i => rStatus.get(i) != "pending" implies ticksSinceOpen.get(i) == 0),
    safetyInvariants,
  }

  // Refinement of `requestsAbstract` on top of the base induction.
  val refinesInv = and { inductiveInv, movesAreAbsSteps }
}
