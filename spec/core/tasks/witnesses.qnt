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

  // A prompt typed at idle (offer! :turn 0) starts turn 1 at the idle tick.
  run turnOne =
    R::init.then(R::doOffer(0, false)).then(R::doStartTurn)

  // A tool request inside a turn is answered and unparks the turn.
  run reachToolReqAnsweredTest =
    turnOne.then(R::doOpenReq(1, true, 2)).then(R::doAnswer(1))
      .then(R::doEndTurn)
      .expect(R::rStatus.get(1) == "answered" and R::kind == "none" and R::allInvariants)

  // A tool request with budget 2 counts down and resolves on the 2nd tick.
  run reachCountdownTimeoutUnparksTest =
    turnOne.then(R::doOpenReq(1, true, 2))
      .then(R::doTick(1)).then(R::doTick(1))
      .expect(R::rStatus.get(1) == "timeout" and R::parkedOn == -1
              and R::rRem.get(1) == 0 and R::allInvariants)

  // Opening a request when no resolver is present resolves immediately to timeout.
  run reachNoResolverImmediateFallbackTest =
    R::init.then(R::doSetResolver(false)).then(R::doOffer(0, false)).then(R::doStartTurn)
      .then(R::doOpenReq(1, true, 2))
      .expect(R::rStatus.get(1) == "timeout" and R::parkedOn == -1
              and R::rRes.get(1) == 1 and R::allInvariants)

  // An idle picker whose continuation is answered after a turn started aborts (#638).
  run reachIdlePickerAbortedWhenBusyTest =
    R::init.then(R::doOpenReq(1, false, 2)).then(R::doOffer(0, false)).then(R::doStartTurn)
      .then(R::doAnswer(1))
      .expect(R::rStatus.get(1) == "aborted" and R::kind == "turn" and R::allInvariants)

  // /reload is an exclusive job: requested, started by next-job!, its body
  // cancels pending idle pickers and advances the generation, then released.
  run reachReloadCancelsIdlePickerTest =
    R::init.then(R::doOpenReq(1, false, 2)).then(R::doRequestReload)
      .then(R::doStartExclusive).then(R::doReload).then(R::doEndExclusive)
      .expect(R::rStatus.get(1) == "cancelled" and R::gen == 1 and R::kind == "none"
              and R::hid == 1 and R::n == 0 and R::allInvariants)

  // A pending turn start goes before a requested /reload job.
  run reachTurnStartBeforeReloadTest =
    R::init.then(R::doRequestReload).then(R::doOffer(0, false))
      .then(R::doStartTurn).then(R::doEndTurn).then(R::doStartExclusive)
      .expect(R::kind == "exclusive" and R::n == 1 and R::allInvariants)

  // A line typed during /reload (offer! without :turn) is not refused: it
  // waits as a follow-up and starts the next turn once the job releases.
  run reachTypedDuringReloadStartsTurnTest =
    R::init.then(R::doRequestReload).then(R::doStartExclusive).then(R::doOffer(-1, false))
      .then(R::doEndExclusive).then(R::doStartTurn)
      .expect(R::kind == "turn" and R::why.get(0) == "started" and R::whyN.get(0) == 1
              and R::allInvariants)

  // Steering for a turn that ends before reading it is handed back
  // (released, attributed to that turn), not carried into the next turn.
  run reachSteeringReturnedAtTurnEndTest =
    turnOne.then(R::doOffer(1, false)).then(R::doEndTurn)
      .expect(R::why.get(1) == "released" and R::whyN.get(1) == 1 and R::steer == Set()
              and R::allInvariants)

  // Steering wins: the running turn's line is taken before a queued follow-up.
  run reachSteeringBeforeFollowUpTest =
    turnOne.then(R::doOffer(1, false)).then(R::doOffer(-1, true))
      .then(R::doTakeSteer).then(R::doTakeFollowUp)
      .expect(R::why.get(1) == "taken" and R::why.get(2) == "taken" and R::orderOk
              and R::allInvariants)

  // A parked turn takes no steering until its request resolves.
  run reachAnswerUnparksThenSteerTakenTest =
    turnOne.then(R::doOffer(1, false)).then(R::doOpenReq(1, true, 2)).then(R::doAnswer(1))
      .then(R::doTakeSteer)
      .expect(R::why.get(1) == "taken" and R::parkedOn == -1 and R::allInvariants)
}
