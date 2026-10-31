// The abstract subagent run and mailbox machine (#674), checked on its own.
// Its invariants hold inductively (verify.tsv), so every concrete model
// that refines absNext inherits them.
module runsSpec {
  import runsAbstract.* from "./abstract"

  pure val MAX_CONTROLS = 1
  pure val CTL_PAIRS: Set[(int, int)] = Set((0, 0), (1, 0), (1, 1))
  pure val CTL_SETTLED: Set[(int, int)] = Set((0, 0), (1, 1))
  pure val ACTIVE_MODES: Set[str] = Set("blocking", "background")
  pure val LIVE_STATUSES: Set[str] = Set("running", "finalizing")
  pure val TERMINAL_STATUSES: Set[str] = Set("done", "cancelled")
  pure val OUTCOME_STATES: Set[(bool, bool)] = Set((true, false), (false, true))

  pure val ABS_STATES: Set[Abs] =
    Set(absInit)
      .union(
        tuples(ACTIVE_MODES, LIVE_STATUSES, CTL_PAIRS).map(t =>
          { mode: t._1, status: t._2, alive: true, mailbox: false, delivered: false,
            sentCtl: t._3._1, ackedCtl: t._3._2 }
        )
      )
      .union(
        tuples(ACTIVE_MODES, TERMINAL_STATUSES, CTL_SETTLED, OUTCOME_STATES).map(t =>
          { mode: t._1, status: t._2, alive: false, mailbox: t._4._1, delivered: t._4._2,
            sentCtl: t._3._1, ackedCtl: t._3._2 }
        )
      )

  var a: Abs
  var prev: Abs

  action init = all { a' = absInit, prev' = absInit }

  action move(b: Abs): bool = all { a' = b, prev' = a }

  action doLaunch(m: str): bool = all {
    a.status == "none",
    m != "none",
    move({ ...a, mode: m, status: "running", alive: true }),
  }

  action doSendControl = all {
    a.alive,
    a.sentCtl < MAX_CONTROLS,
    move({ ...a, sentCtl: a.sentCtl + 1 }),
  }

  action doAckControl = all {
    a.alive,
    a.ackedCtl < a.sentCtl,
    move({ ...a, ackedCtl: a.ackedCtl + 1 }),
  }

  action doFinalize = all {
    a.alive,
    a.status == "running",
    move({ ...a, status: "finalizing" }),
  }

  action doFinish = all {
    a.alive,
    live(a.status),
    move({ ...a, status: "done", alive: false, mailbox: true, ackedCtl: a.sentCtl }),
  }

  action doReap = all {
    a.alive,
    live(a.status),
    move({ ...a, status: "cancelled", alive: false, mailbox: true, ackedCtl: a.sentCtl }),
  }

  action doDeliver = all {
    terminal(a.status),
    a.mailbox,
    not(a.delivered),
    move({ ...a, mailbox: false, delivered: true }),
  }

  action doStutter = all {
    a' = a,
    prev' = a,
  }

  action step = any {
    nondet m = Set("blocking", "background").oneOf()
    doLaunch(m),
    doSendControl,
    doAckControl,
    doFinalize,
    doFinish,
    doReap,
    doDeliver,
    doStutter,
  }

  // ---- properties ----

  val movesAreAbsSteps = absNext(prev, a)
  val statusMatchesProcessInv = statusMatchesProcess(a)
  val unlaunchedEmptyInv = unlaunchedEmpty(a)
  val toldOrPendingInv = toldOrPending(a)
  val mailboxDeliveredDisjointInv = mailboxDeliveredDisjoint(a)
  val mailboxOnlyWhenTerminalInv = mailboxOnlyWhenTerminal(a)
  val deliveredOnlyWhenTerminalInv = deliveredOnlyWhenTerminal(a)
  val controlsAckedBoundedInv = controlsAckedBounded(a)
  val controlsSettledAtTerminalInv = controlsSettledAtTerminal(a)

  val inductiveInv = and {
    a.in(ABS_STATES),
    prev.in(ABS_STATES),
    absInv(a),
  }

  val allInvariants = and {
    movesAreAbsSteps,
    statusMatchesProcessInv,
    unlaunchedEmptyInv,
    toldOrPendingInv,
    mailboxDeliveredDisjointInv,
    mailboxOnlyWhenTerminalInv,
    deliveredOnlyWhenTerminalInv,
    controlsAckedBoundedInv,
    controlsSettledAtTerminalInv,
    inductiveInv,
  }
}
