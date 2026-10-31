// The abstract process job machine (#670), checked on its own: every move an
// owner or runtime environment of the process group can make. Its invariants
// hold at any depth (verify.tsv: inductive), so every concrete model that
// refines absNext inherits them.
module jobSpec {
  import jobAbstract.* from "./abstract"

  pure val RUN_OUT = 0.to(BODY_LIMIT)
  pure val DONE_OUT = TRAILER_SIZE.to(MAX_LIMIT)

  pure val RUN_FLAGS: Set[{ la: bool, ma: bool, ts: bool, ks: bool, tout: bool, c: bool }] =
    Bool.map(la => Bool.map(ma =>
      Set(
        // Normal running
        { ts: false, ks: false, tout: false, c: false },
        // Cancelled before timeout (kill sent)
        { ts: false, ks: true, tout: false, c: true },
        // Timeout, term sent
        { ts: true, ks: false, tout: true, c: false },
        // Timeout, grace expired (kill sent)
        { ts: true, ks: true, tout: true, c: false },
        // Cancelled after timeout
        { ts: true, ks: true, tout: true, c: true }
      ).map(f => { la: la, ma: ma, ts: f.ts, ks: f.ks, tout: f.tout, c: f.c })
    ).flatten()).flatten()

  pure val DONE_FLAGS: Set[{ ma: bool, ts: bool, ks: bool, tout: bool, c: bool, oc: str }] =
    Bool.map(ma =>
      Set(
        // Normal ok/error finish
        { ts: false, ks: false, tout: false, c: false, oc: "ok" },
        { ts: false, ks: false, tout: false, c: false, oc: "error" },
        // Timeout finish (no surviving members)
        { ts: true, ks: false, tout: true, c: false, oc: "timeout" },
        { ts: true, ks: true, tout: true, c: false, oc: "timeout" },
        // Cancelled finish (no surviving members)
        { ts: false, ks: true, tout: false, c: true, oc: "cancelled" },
        { ts: true, ks: true, tout: true, c: true, oc: "cancelled" }
      ).filter(f => (f.tout or f.c) implies not(ma))
       .map(f => { ma: ma, ts: f.ts, ks: f.ks, tout: f.tout, c: f.c, oc: f.oc })
    ).flatten()

  pure val ABS_STATES: Set[Abs] =
    Set(absInit)
    .union(
      RUN_FLAGS.map(f => RUN_OUT.map(ol => Bool.map(tr =>
        { phase: "running", leaderAlive: f.la, membersAlive: f.ma, termSent: f.ts,
          killSent: f.ks, timedOut: f.tout, cancelled: f.c, outLen: ol, truncated: tr,
          hasTrailer: false, outcome: "none" }
      )).flatten()).flatten()
    )
    .union(
      DONE_FLAGS.map(f => DONE_OUT.map(ol => Bool.map(tr =>
        { phase: "done", leaderAlive: false, membersAlive: f.ma, termSent: f.ts,
          killSent: f.ks, timedOut: f.tout, cancelled: f.c, outLen: ol, truncated: tr,
          hasTrailer: true, outcome: f.oc }
      )).flatten()).flatten()
    )

  var a: Abs
  var prev: Abs // ghost: state before the last step

  action init = all { a' = absInit, prev' = absInit }

  action move(b: Abs): bool = all { a' = b, prev' = a }

  action doSpawn = all {
    a.phase == "idle",
    move({ ...absInit, phase: "running", leaderAlive: true, membersAlive: true }),
  }

  action doAppendOutput = all {
    a.phase == "running",
    val nextLen = if (a.outLen < BODY_LIMIT) a.outLen + 1 else BODY_LIMIT
    val trunc = a.truncated or (a.outLen >= BODY_LIMIT)
    move({ ...a, outLen: nextLen, truncated: trunc }),
  }

  action doLeaderExit = all {
    a.phase == "running", a.leaderAlive,
    move({ ...a, leaderAlive: false }),
  }

  action doMemberExit = all {
    a.phase == "running", a.membersAlive,
    move({ ...a, membersAlive: false }),
  }

  action doTimeout(lexit: bool, mexit: bool): bool = all {
    a.phase == "running", not(a.timedOut), not(a.termSent),
    move({ ...a, timedOut: true, termSent: true,
           leaderAlive: if (lexit) false else a.leaderAlive,
           membersAlive: if (mexit) false else a.membersAlive }),
  }

  action doGraceExpired = all {
    a.phase == "running", a.termSent, not(a.killSent),
    move({ ...a, killSent: true, leaderAlive: false, membersAlive: false }),
  }

  action doCancel = all {
    a.phase == "running", not(a.cancelled),
    move({ ...a, cancelled: true, killSent: true, leaderAlive: false, membersAlive: false }),
  }

  action doFinish(normalOutcome: str): bool = all {
    a.phase == "running", not(a.leaderAlive),
    normalOutcome.in(Set("ok", "error")),
    val oc = if (a.cancelled) "cancelled" else if (a.timedOut) "timeout" else normalOutcome
    val mems = if (a.timedOut or a.cancelled) false else a.membersAlive
    val killed = a.killSent or ((a.timedOut or a.cancelled) and a.membersAlive)
    move({ ...a, phase: "done", membersAlive: mems, killSent: killed,
           hasTrailer: true, outcome: oc, outLen: a.outLen + TRAILER_SIZE }),
  }

  action step = any {
    doSpawn,
    doAppendOutput,
    doLeaderExit,
    doMemberExit,
    nondet lexit = Bool.oneOf()
    nondet mexit = Bool.oneOf()
    doTimeout(lexit, mexit),
    doGraceExpired,
    doCancel,
    nondet oc = Set("ok", "error").oneOf()
    doFinish(oc),
  }

  // ---- properties ----

  val movesAreAbsSteps = absNext(prev, a)

  val noLiveProcessAfterAbnormalInv = noLiveProcessAfterAbnormal(a)
  val leaderReapedWhenDoneInv = leaderReapedWhenDone(a)
  val killOnlyAbnormalInv = killOnlyAbnormal(a)
  val trailerWhenDoneInv = trailerWhenDone(a)
  val outcomeConsistentInv = outcomeConsistent(a)
  val outputWithinLimitInv = outputWithinLimit(a)

  val inductiveInv = and {
    a.in(ABS_STATES),
    prev.in(ABS_STATES),
    absInv(a),
    a.termSent == a.timedOut,
  }

  val allInvariants = and {
    movesAreAbsSteps,
    noLiveProcessAfterAbnormalInv,
    leaderReapedWhenDoneInv,
    killOnlyAbnormalInv,
    trailerWhenDoneInv,
    outcomeConsistentInv,
    outputWithinLimitInv,
    inductiveInv,
  }
}
