// The abstract task table machine (#671), checked on its own: every move an
// owner, coroutine, or scheduler loop can make. Its invariants hold at any
// depth (verify.tsv: inductive), so every concrete model that refines absNext
// inherits them.
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
