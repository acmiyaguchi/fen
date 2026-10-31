// Witnesses for the loop proof model: each issue is a refinement failure of
// today's loop; the fixed loop refines the spec through its interesting cases.
module witnesses {
  import loopProof(FIXES = Set()) as C from "./model"
  import loopProof(FIXES = Set("606", "607", "608", "609", "610")) as F from "./model"

  run w606LengthReplyClosesOpenTest =
    C::init.then(C::startStep(false)).then(C::loopTop).then(C::provider("length"))
      .then(C::afterLlm).expect(not(C::refinesTurn))

  run w607CrashClosesOpenTest =
    C::init.then(C::startStep(false)).then(C::loopTop).then(C::provider("badArgs"))
      .then(C::afterLlm).expect(not(C::refinesTurn))

  run w608UnowedReplyTest =
    C::init.then(C::startStep(false)).then(C::enqueue("empty")).then(C::loopTop)
      .then(C::provider("text")).then(C::afterLlm).then(C::loopTop).then(C::provider("text"))
      .expect(not(C::refinesTurn))

  run w609RefusedTwiceClosesOkTest =
    C::init.then(C::startStep(true)).then(C::loopTop).then(C::provider("tool1")).then(C::afterLlm)
      .then(C::loopTop).then(C::provider("tool1")).then(C::afterLlm)
      .expect(not(C::refinesTurn))

  run w610CapClosesOkTest =
    C::init.then(C::startStep(false))
      .then(C::loopTop).then(C::provider("tool1")).then(C::afterLlm).then(C::toolRun)
      .then(C::loopTop).then(C::provider("tool1")).then(C::afterLlm).then(C::toolRun)
      .then(C::loopTop)
      .expect(not(C::refinesTurn))

  run reachToolRoundOkTest =
    F::init.then(F::startStep(false)).then(F::loopTop).then(F::provider("tool2"))
      .then(F::afterLlm).then(F::toolRun).then(F::toolRun).then(F::loopTop)
      .then(F::provider("text")).then(F::afterLlm)
      .expect(F::l.result == "ok" and F::refinesTurn and F::inheritsTurnInvariants)

  run reachCancelMidToolsTest =
    F::init.then(F::startStep(false)).then(F::loopTop).then(F::provider("tool2"))
      .then(F::afterLlm).then(F::toolRun).then(F::cancel)
      .expect(F::l.result == "cancelled" and F::refinesTurn and F::inheritsTurnInvariants)

  run reachCrashClosedTest =
    F::init.then(F::startStep(false)).then(F::loopTop).then(F::provider("badArgs"))
      .then(F::afterLlm)
      .expect(F::l.result == "crash" and F::refinesTurn and F::inheritsTurnInvariants)

  run reachCapErrorTest =
    F::init.then(F::startStep(false))
      .then(F::loopTop).then(F::provider("tool1")).then(F::afterLlm).then(F::toolRun)
      .then(F::loopTop).then(F::provider("tool1")).then(F::afterLlm).then(F::toolRun)
      .then(F::loopTop)
      .expect(F::l.result == "error" and F::refinesTurn and F::inheritsTurnInvariants)

  run reachFollowUpLineTest =
    F::init.then(F::startStep(false)).then(F::enqueue("line")).then(F::loopTop)
      .then(F::provider("text")).then(F::afterLlm).then(F::loopTop).then(F::provider("text"))
      .expect(F::refinesTurn and F::inheritsTurnInvariants)
}
