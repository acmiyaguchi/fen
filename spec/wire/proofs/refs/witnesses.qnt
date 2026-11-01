// Reachability for the ref-accounting proof model, so its inductive proof is
// not vacuous: every kind of terminal notice, and both fixed paths, happen.
module witnesses {
  import refs as R from "./model"

  action ready = R::initWith("one", "one").then(R::childStart)

  // A prompt in ready starts turn 1; turn-started names it.
  run reachStartedNoticeTest =
    ready.then(R::parentLine("prompt", false))
      .expect(R::notes.get(0) == 1 and R::hWhy.get(0) == "started" and R::inductive)

  // A steer is injected at a boundary; the injected event names it.
  run reachTakenNoticeTest =
    ready.then(R::parentLine("prompt", false)).then(R::parentLine("steer", false))
      .then(R::takeSteerLines)
      .expect(R::notes.get(1) == 1 and R::hWhy.get(1) == "taken" and R::inductive)

  // The turn ends with the steer unread: steering-returned names it.
  run reachReleasedNoticeTest =
    ready.then(R::parentLine("prompt", false)).then(R::parentLine("steer", false))
      .then(R::bodyExit)
      .expect(R::notes.get(1) == 1 and R::hWhy.get(1) == "released" and R::st == "ready"
              and R::settledAccounted and R::inductive)

  // A steer under an adopted exclusive job is refused by the child itself.
  run reachSteerRefusedUnderExclusiveTest =
    ready.then(R::exStart(true)).then(R::parentLine("steer", false))
      .expect(R::notes.get(0) == 1 and R::hWhy.get(0) == "" and R::inductive)

  // Finalize drops a queued follow-up: the drop info names it.
  run reachClearedByFinalizeTest =
    ready.then(R::parentLine("prompt", false)).then(R::parentLine("follow-up", false))
      .then(R::parentCtl("finalize"))
      .expect(R::notes.get(1) == 1 and R::hWhy.get(1) == "cleared" and R::inductive)

  // A prompt behind an exclusive job waits, then starts; turn-started names it.
  run reachPendingStartTest =
    ready.then(R::exStart(false)).then(R::parentLine("prompt", false))
      .then(R::exEnd).then(R::tickStart)
      .expect(R::active == "turn" and R::notes.get(0) == 1 and R::hWhy.get(0) == "started"
              and R::inductive)

  // Finalize clears that waiting line: it is reported, and the run finishes.
  run reachPendingFinalizeFinishesTest =
    ready.then(R::exStart(false)).then(R::parentLine("prompt", false))
      .then(R::parentCtl("finalize"))
      .expect(R::exited and R::st == "done" and R::notes.get(0) == 1
              and R::hWhy.get(0) == "cleared" and R::inductive)

  // An empty prompt is accepted but cannot start: reported, then exit failed.
  run reachEmptyPromptReportedTest =
    ready.then(R::parentLine("prompt", true))
      .expect(R::exited and R::st == "failed" and R::notes.get(0) == 1 and R::inductive)

  // An empty steer is rejected at ack: no notice.
  run reachRejectedNoNoticeTest =
    ready.then(R::parentLine("prompt", false)).then(R::parentLine("steer", true))
      .expect(R::acked.get(1) == "rejected" and R::notes.get(1) == 0 and R::inductive)

  // Finalize mid-turn, then the forced turn (its own line, slot FIN, has no ref).
  run reachForcedFinalizeTurnTest =
    ready.then(R::parentLine("prompt", false)).then(R::parentCtl("finalize"))
      .then(R::bodyExit).then(R::bodyExit)
      .expect(R::exited and R::st == "done" and R::hWhy.get(3) == "started"
              and R::notes.get(3) == 0 and R::inductive)
}
