// Reachability of the abstract task table machine: each interesting task lifecycle,
// isolation, arm, and fault path actually happens, so the inductive proof is not vacuous.
module witnesses {
  import tasksSpec as T from "./model"

  // Normal lifecycle: spawn task, step (yield), step (finish), retire.
  run reachTaskStepAndFinishTest =
    T::init.then(T::doSpawn(1, 1)).then(T::doDriverStepNormal(1, false))
      .then(T::doDriverStepNormal(1, true)).then(T::doRetire(1))
      .expect(T::a.t1Status == "none" and not(T::a.anyRunnable) and not(T::a.pollActive) and T::allInvariants)

  // Fault isolation: task 1 faults under xpcall, but task 2 continues running.
  run reachFaultIsolatedTest =
    T::init.then(T::doSpawn(1, 1)).then(T::doSpawn(2, 2))
      .then(T::doDriverStepFault(1))
      .expect(T::a.t1Status == "done" and T::a.faultCaught and T::a.t2Status == "ready" and T::a.anyRunnable and T::allInvariants)

  // Scoped cancel arm: arm belongs strictly to owner 1's task and disarms upon completion.
  run reachCancelArmScopedTest =
    T::init.then(T::doSpawn(1, 1)).then(T::doSpawn(2, 2))
      .then(T::doArmCancel(1))
      .then(T::doDriverStepNormal(1, true))
      .expect(not(T::a.t1Armed) and not(T::a.t2Armed) and T::allInvariants)

  // Cadence switches with active work: active when runnable, idle when drained.
  run reachCadenceSwitchesWithWorkTest =
    T::init.then(T::doSpawn(1, 1))
      .then(T::doDriverStepNormal(1, true))
      .expect(not(T::a.pollActive) and not(T::a.anyRunnable) and T::allInvariants)

  // Turn-keyed cancel: cancel request routes strictly to targeted owner.
  run reachTurnKeyedCancelTest =
    T::init.then(T::doSpawn(1, 1)).then(T::doSpawn(2, 2))
      .then(T::doRequestCancel(2))
      .expect(T::a.t2Cancel and not(T::a.t1Cancel) and T::allInvariants)
}
