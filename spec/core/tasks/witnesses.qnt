// Reachability of the abstract task table (`tasksSpec`) and async-request
// ownership (`requestsSpec`) machines (#671, #397, #398), so the inductive
// proofs are not vacuous.
module witnesses {
  import tasksSpec as T from "./model"
  import requestsSpec as R from "./model"

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

  // A tool request inside a turn is answered and unparks the turn.
  run reachToolReqAnsweredTest =
    R::init.then(R::doStartTurn).then(R::doOpenReq(1, true, 2)).then(R::doAnswer(1))
      .then(R::doEndTurn)
      .expect(R::rStatus.get(1) == "answered" and not(R::running) and R::allInvariants)

  // A tool request with budget 2 counts down and resolves on the 2nd tick.
  run reachCountdownTimeoutUnparksTest =
    R::init.then(R::doStartTurn).then(R::doOpenReq(1, true, 2))
      .then(R::doTick(1)).then(R::doTick(1))
      .expect(R::rStatus.get(1) == "timeout" and R::parkedOn == -1
              and R::rRem.get(1) == 0 and R::allInvariants)

  // Opening a request when no resolver is present resolves immediately to timeout.
  run reachNoResolverImmediateFallbackTest =
    R::init.then(R::doSetResolver(false)).then(R::doStartTurn)
      .then(R::doOpenReq(1, true, 2))
      .expect(R::rStatus.get(1) == "timeout" and R::parkedOn == -1
              and R::rRes.get(1) == 1 and R::allInvariants)

  // An idle picker whose continuation is answered after a turn started aborts (#638).
  run reachIdlePickerAbortedWhenBusyTest =
    R::init.then(R::doOpenReq(1, false, 2)).then(R::doStartTurn).then(R::doAnswer(1))
      .expect(R::rStatus.get(1) == "aborted" and R::running and R::allInvariants)

  // /reload cancels pending idle pickers and advances generation.
  run reachReloadCancelsIdlePickerTest =
    R::init.then(R::doOpenReq(1, false, 2)).then(R::doReload)
      .expect(R::rStatus.get(1) == "cancelled" and R::gen == 1 and R::allInvariants)
}
