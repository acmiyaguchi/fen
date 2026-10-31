// Deterministic witnesses for the steering proof model.
module witnesses {
  import steering(FIXES = Set()) as C from "./model"
  import steering(FIXES = Set("662")) as F from "./model"

  // #662: a line typed for turn 1, which errors, is injected into turn 2.
  run w662SteeringIntoNextTurnTest =
    C::init.then(C::submit).then(C::queueSteer).then(C::finish("error")).then(C::submit)
      .expect(not(C::steeringReachesItsTurn) and C::turn == 2 and C::delivered == 1)

  // #662: the cancel path does the same.
  run w662CancelledTurnSteeringTest =
    C::init.then(C::submit).then(C::queueSteer).then(C::finish("cancelled")).then(C::submit)
      .expect(not(C::steeringReachesItsTurn) and C::qFor == 1)

  run reachHandedBackTest =
    F::init.then(F::submit).then(F::queueSteer).then(F::finish("error")).then(F::submit)
      .expect(F::returned == 1 and F::delivered == 0 and F::steeringInductive)

  run reachDeliveredMidTurnTest =
    F::init.then(F::submit).then(F::queueSteer).then(F::takeQueue).then(F::finish("ok"))
      .expect(F::delivered == 1 and F::steeringInductive)

  run reachDeliveredAtNaturalStopTest =
    F::init.then(F::submit).then(F::queueSteer).then(F::queueSteer).then(F::finish("ok"))
      .expect(F::delivered == 2 and F::steeringInductive)
}
