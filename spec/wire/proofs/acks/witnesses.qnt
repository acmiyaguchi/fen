// Deterministic witnesses for the per-control ack proof model.
module witnesses {
  import acks(FIXES = Set()) as C from "./model"
  import acks(FIXES = Set("664")) as F from "./model"

  // #664: every read control is acked under batching.
  run reach664BatchSkipsSteerTest =
    F::initWith("close", "steer").then(F::childStart).then(F::childPoll).then(F::childApply)
      .then(F::childTurnEnd).then(F::parentAppend).then(F::parentAppend)
      .then(F::childPoll).then(F::childApply).then(F::childApply)
      .expect(F::everyReadControlAcked and F::exited and F::a2 == 1)

  // The fixed loop acks both, then sends result and exit done.
  run reachBatchFullyAckedTest =
    F::initWith("close", "steer").then(F::childStart).then(F::childPoll).then(F::childApply)
      .then(F::childTurnEnd).then(F::parentAppend).then(F::parentAppend)
      .then(F::childPoll).then(F::childApply).then(F::childApply)
      .expect(F::fixedInductive and F::exited and F::a2 == 1 and F::results == 1)

  // Cancel mid-turn: acked, the turn unwinds, exit cancelled, no result.
  run reachCancelTest =
    F::initWith("cancel", "steer").then(F::childStart).then(F::parentAppend)
      .then(F::childPoll).then(F::childApply).then(F::childApply).then(F::childTurnEnd)
      .expect(F::fixedInductive and F::exitStatus == "cancelled" and F::results == 0
              and F::a0 == 1 and F::a1 == 1)

  // Finalize mid-turn, then the forced turn: result once, exit done.
  run reachFinalizeTest =
    F::initWith("finalize", "close").then(F::childStart).then(F::parentAppend)
      .then(F::childPoll).then(F::childApply).then(F::childApply).then(F::childTurnEnd)
      .then(F::parentAppend).then(F::childPoll).then(F::childApply).then(F::childTurnEnd)
      .expect(F::fixedInductive and F::exitStatus == "done" and F::results == 1
              and F::a2 == 1)
}
