// Deterministic witnesses for the steering proof model.
module witnesses {
  import steering(FIXES = Set("662")) as F from "./model"

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
