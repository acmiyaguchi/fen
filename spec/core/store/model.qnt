// The abstract store machine (#669), checked on its own: every move an owner
// or environment of the kernel-locked, compare-and-rename store can make.
// Its invariants hold at any depth (verify.tsv: inductive), so every concrete
// model that refines absNext inherits them.
module storeSpec {
  import storeAbstract.* from "./abstract"

  pure val PROCS = Set(1, 2)
  pure val VALS = Set(0, 1, 2)

  pure val ABS_STATES: Set[Abs] =
    // Unlocked idle states: holder 0
    VALS.map(v => { holder: 0, store: v, staged: -1, snap: -1, status: "idle" })
    .union(
      // Locked staged states: holder in PROCS, staged in VALS, snap in VALS
      PROCS.map(p => VALS.map(st => VALS.map(sn => VALS.map(v =>
        { holder: p, store: v, staged: st, snap: sn, status: "staged" }
      )).flatten()).flatten()).flatten()
    )
    .union(
      // Locked unstaged states: status in {"idle", "committed", "conflict", "aborted"}
      PROCS.map(p => Set("idle", "committed", "conflict", "aborted").map(st => VALS.map(v =>
        { holder: p, store: v, staged: -1, snap: -1, status: st }
      )).flatten()).flatten()
    )

  var a: Abs
  var prev: Abs // ghost: state before the last step

  action init = all { a' = absInit, prev' = absInit }

  action move(b: Abs): bool = all { a' = b, prev' = a }

  action doAcquire(p: int): bool = all {
    a.holder == 0,
    move({ ...a, holder: p, status: "idle" }),
  }

  action doStage(newVal: int): bool = all {
    a.holder != 0, a.staged == -1,
    move({ ...a, staged: newVal, snap: a.store, status: "staged" }),
  }

  action doCommit = all {
    a.holder != 0, a.status == "staged",
    if (a.snap == a.store)
      move({ ...a, store: a.staged, staged: -1, snap: -1, status: "committed" })
    else
      move({ ...a, staged: -1, snap: -1, status: "conflict" }),
  }

  action doAbort = all {
    a.holder != 0, a.status == "staged",
    move({ ...a, staged: -1, snap: -1, status: "aborted" }),
  }

  action doRelease = all {
    a.holder != 0, a.staged == -1,
    move({ ...a, holder: 0, status: "idle" }),
  }

  action doCrash = all {
    a.holder != 0,
    move({ ...a, holder: 0, staged: -1, snap: -1, status: "idle" }),
  }

  action doOutsideWrite(newVal: int): bool = all {
    newVal != a.store,
    move({ ...a, store: newVal }),
  }

  action step = any {
    nondet p = PROCS.oneOf()
    doAcquire(p),
    nondet v = VALS.oneOf()
    doStage(v),
    doCommit,
    doAbort,
    doRelease,
    doCrash,
    nondet v = VALS.oneOf()
    doOutsideWrite(v),
  }

  // ---- properties ----

  val movesAreAbsSteps = absNext(prev, a)

  val stagedRequiresLockInv = stagedRequiresLock(a)
  val snapPairedWithStagedInv = snapPairedWithStaged(a)
  val unlockedIsIdleInv = unlockedIsIdle(a)
  val statusConsistentInv = statusConsistent(a)

  val inductiveInv = and {
    a.in(ABS_STATES),
    prev.in(ABS_STATES),
    absInv(a),
  }

  val allInvariants = and {
    movesAreAbsSteps,
    stagedRequiresLockInv,
    snapPairedWithStagedInv,
    unlockedIsIdleInv,
    statusConsistentInv,
    inductiveInv,
  }
}
