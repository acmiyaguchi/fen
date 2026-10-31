// Reachability of the abstract close-turn machine: each interesting way a
// turn can go actually happens, so the inductive proof is not vacuous.
module witnesses {
  import turnSpec as T from "./model"

  // A turn with a tool round that ends in a plain reply, closed ok.
  run reachToolRoundClosedOkTest =
    T::init.then(T::doUserInput).then(T::doReply([0])).then(T::doAnswer(1))
      .then(T::doReply([])).then(T::doClose("ok"))
      .expect(T::a.outcome == "ok" and T::allInvariants)

  // A cancel with two calls open: close pairs both.
  run reachCancelPairsOpenCallsTest =
    T::init.then(T::doUserInput).then(T::doReply([0, 1])).then(T::doClose("cancelled"))
      .expect(T::a.open == [] and T::a.awaiting and T::allInvariants)

  // A parallel batch answers both calls in one step.
  run reachBatchAnswerTest =
    T::init.then(T::doUserInput).then(T::doReply([0, 1])).then(T::doAnswer(2))
      .expect(T::a.awaiting and T::allInvariants)

  // An announced error closes the turn with an error.
  run reachErrorCloseTest =
    T::init.then(T::doUserInput).then(T::doSignalError).then(T::doClose("error"))
      .expect(T::a.outcome == "error" and T::allInvariants)

  // Steering inside an open turn, then a second turn.
  run reachSteeringAndSecondTurnTest =
    T::init.then(T::doUserInput).then(T::doReply([])).then(T::doUserInput)
      .then(T::doReply([])).then(T::doClose("ok")).then(T::doUserInput)
      .expect(T::a.turnOpen and T::a.outcome == "none" and T::allInvariants)
}
