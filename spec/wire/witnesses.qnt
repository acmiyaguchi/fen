// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows a fixed instance still reaches the case it guards
// (completion, held or rejected steers, cancel, deadline, fatal, spill).
module witnesses {
  import wire(FIXES = Set()) as C from "./model"
  import wire(FIXES = Set("664", "665", "666", "667")) as F from "./model"

  pure def acks(out: List[C::Ev], s: int): int = C::ackCount(out, s)

  // #664: every read control is acked under batching.
  run reach664BatchSkipsSteerTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::childAnswer)
      .then(F::parentPollAll).then(F::parentDrive).then(F::userSteer(false))
      .then(F::childPoll)
      .expect(F::allInvariants and F::c.exited)

  // #664: drive! does not send steer once close is already out.
  run reach664DoomedSteerSentTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::childAnswer)
      .then(F::parentPollAll).then(F::parentDrive).then(F::userSteer(false))
      .expect(F::noDoomedSteer and F::p.closeSent and F::canSteer(F::p) == false)

  // #664: the run settles with the user's steer reported dropped at settle.
  run reach664SteerUnreportedTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::childAnswer)
      .then(F::parentPollAll).then(F::parentDrive).then(F::userSteer(false))
      .then(F::childPoll).then(F::parentSettle)
      .expect(F::userSteersAccounted and F::settled and F::p.exitSeen
              and F::p.localReported != Set())

  // #665: finalize in ready keeps the natural answer and finishes the run.
  run reach665FinalizeReplacesAnswerTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::childToolCall)
      .then(F::parentPollAll).then(F::childAnswer).then(F::parentDrive)
      .then(F::childPoll)
      .expect(F::naturalAnswerKept and F::c.st == "done" and F::c.turns == 1)

  // #666: an empty steer is rejected, and queued steers are accounted.
  run reach666EmptySteerUnaccountedTest =
    F::initWith("empty").then(F::childStart).then(F::childPoll).then(F::parentPollAll)
      .then(F::userSteer(true)).then(F::userSteer(false)).then(F::parentDrive)
      .then(F::childPoll).then(F::childInject)
      .then(F::childAnswer).then(F::parentPollAll).then(F::parentDrive)
      .then(F::childPoll)
      .expect(F::queuedSteersAccounted and F::c.exited)

  // #667: the parent names the spill file and always removes it even on crash.
  run reach667SpillLeaksOnCrashTest =
    F::initWith("longCrash").then(F::childStart).then(F::childPoll)
      .then(F::envLongAnswer).then(F::envCrashAtResult).then(F::childAnswer)
      .then(F::parentPollAll).then(F::parentDrive).then(F::childPoll)
      .then(F::parentSettle)
      .expect(F::finalTextFileRemovedOnce and F::settled and F::removals == 1)

  // ---- reachability of the fixed design ----

  pure def lastKinds(out: List[F::Ev]): List[str] =
    out.slice(out.length() - 2, out.length()).foldl([], (a, e) => a.append(e.kind))

  // A run completes: prompt, answer, close, result, exit done.
  run reachCompleteTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::childAnswer)
      .then(F::parentPollAll).then(F::parentDrive).then(F::childPoll)
      .then(F::parentSettle)
      .expect(and {
        F::allInvariants, F::settled, F::c.exited, F::p.gotResult,
        lastKinds(F::c.out) == ["result", "exit"], F::c.out[F::c.out.length() - 1].status == "done",
      })

  // A steer mid-turn is queued and injected with its ref.
  run reachSteerInjectedTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::parentPollAll)
      .then(F::userSteer(false)).then(F::parentDrive).then(F::childPoll)
      .then(F::childInject).then(F::childAnswer).then(F::parentPollAll)
      .then(F::parentDrive).then(F::childPoll).then(F::parentSettle)
      .expect(F::allInvariants and F::p.reportedSeqs.contains(2) and F::c.exited)

  // The #664 schedule: the steer requested after close is held and reported
  // dropped at settle; every read control is acked.
  run reachSteerAfterCloseReportedTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::childAnswer)
      .then(F::parentPollAll).then(F::parentDrive).then(F::userSteer(false))
      .then(F::childPoll).then(F::parentSettle)
      .expect(F::allInvariants and F::p.localReported == Set(0) and F::p.seq == 2)

  // Two controls in one batch that end the run are both acked.
  run reachBatchFullyAckedTest =
    F::initWith("external").then(F::childStart).then(F::childPoll)
      .then(F::externalControl("close")).then(F::externalControl("finalize"))
      .then(F::childAnswer).then(F::childPoll)
      .expect(F::allInvariants and acks(F::c.out, 2) == 1 and acks(F::c.out, 3) == 1)

  // The #665 schedule: finalize in ready keeps the first answer.
  run reachFinalizeKeepsAnswerTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::childToolCall)
      .then(F::parentPollAll).then(F::childAnswer).then(F::parentDrive)
      .then(F::childPoll)
      .expect(F::allInvariants and F::c.exited and F::c.turns == 1 and F::p.finalizeSent)

  // A budget finalize while the turn is running interrupts it and runs the
  // tool-free turn.
  run reachFinalizeTurnTest =
    F::initWith("none").then(F::childStart).then(F::childPoll).then(F::childToolCall)
      .then(F::parentPollAll).then(F::parentDrive).then(F::childPoll)
      .then(F::childUnwind).then(F::childAnswer)
      .expect(F::allInvariants and F::c.exited and F::c.turns == 2)

  // The #666 schedule: the empty steer is rejected, the real one injected
  // with its ref.
  run reachEmptySteerRejectedTest =
    F::initWith("empty").then(F::childStart).then(F::childPoll).then(F::parentPollAll)
      .then(F::userSteer(true)).then(F::userSteer(false)).then(F::parentDrive)
      .then(F::childPoll).then(F::childInject)
      .expect(and {
        F::allInvariants, F::c.accepted == Set(3),
        F::c.out.select(e => e.kind == "injected" and e.ref == 3).length() == 1,
      })

  // The #667 schedule: the parent-named spill file is removed.
  run reachSpillRemovedOnCrashTest =
    F::initWith("longCrash").then(F::childStart).then(F::childPoll)
      .then(F::envLongAnswer).then(F::envCrashAtResult).then(F::childAnswer)
      .then(F::parentPollAll).then(F::parentDrive).then(F::childPoll)
      .then(F::parentSettle)
      .expect(F::allInvariants and F::c.spilled and F::removals == 1)

  // Cancel mid-turn unwinds to exit cancelled.
  run reachCancelTest =
    F::initWith("cancel").then(F::childStart).then(F::childPoll).then(F::userCancel)
      .then(F::parentDrive).then(F::childPoll).then(F::childUnwind)
      .then(F::parentSettle)
      .expect(F::allInvariants and F::c.exited and F::p.st == "cancelled")

  // The deadline mid-turn unwinds to exit timed-out.
  run reachDeadlineTest =
    F::initWith("deadline").then(F::childStart).then(F::childPoll).then(F::childDeadline)
      .then(F::childUnwind).then(F::parentPollAll)
      .expect(F::allInvariants and F::c.exited and F::p.st == "timed-out")

  // A fatal error outside a turn (idle child) exits failed at once.
  run reachFatalIdleTest =
    F::initWith("fatal").then(F::childStart).then(F::childPoll).then(F::childAnswer)
      .then(F::childFatal).then(F::parentPollAll)
      .expect(F::allInvariants and F::c.exited and F::p.st == "failed"
              and F::mirrorAgreesWhenDrained)

  // A fatal error mid-turn waits for the unwind, then exits failed.
  run reachFatalMidTurnTest =
    F::initWith("fatal").then(F::childStart).then(F::childPoll).then(F::childFatal)
      .then(F::childUnwind).then(F::parentPollAll)
      .expect(F::allInvariants and F::c.exited and F::p.st == "failed")

  // A turn that throws exits failed after its turn-complete.
  run reachTurnThrowTest =
    F::initWith("fatal").then(F::childStart).then(F::childPoll).then(F::childTurnThrow)
      .then(F::parentPollAll)
      .expect(F::allInvariants and F::c.exited and F::p.st == "failed"
              and lastKinds(F::c.out) == ["turnComplete", "exit"])
}
