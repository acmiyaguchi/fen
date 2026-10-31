// Witnesses for the loop proof model. Today's loop (`current`, which now
// carries the #606-#610 fixes) refines the spec through its interesting cases;
// each reach6xx test replays the trace that once broke refinement for that
// issue (#606-#610, fixed by the close-turn boundary, #668).
module witnesses {
  import loopProof(FIXES = Set("606", "607", "608", "609", "610")) as F from "./model"

  // #606: a :length reply carrying a call takes the tool path.
  run reach606LengthReplyRunsToolTest =
    F::init.then(F::startStep(false)).then(F::loopTop).then(F::provider("length"))
      .then(F::afterLlm).expect(F::l.pc == "tools" and F::refinesTurn and F::inheritsTurnInvariants)

  // #608: an empty queued line ends the step instead of asking again.
  run reach608EmptyLineEndsStepTest =
    F::init.then(F::startStep(false)).then(F::enqueue("empty")).then(F::loopTop)
      .then(F::provider("text")).then(F::afterLlm)
      .expect(F::l.pc == "idle" and F::l.result == "ok" and F::refinesTurn)

  // #609: a refused-twice turn closes with an error.
  run reach609RefusedTwiceErrorTest =
    F::init.then(F::startStep(true)).then(F::loopTop).then(F::provider("tool1")).then(F::afterLlm)
      .then(F::loopTop).then(F::provider("tool1")).then(F::afterLlm)
      .expect(F::l.result == "error" and F::refinesTurn and F::inheritsTurnInvariants)

  run reachToolRoundOkTest =
    F::init.then(F::startStep(false)).then(F::loopTop).then(F::provider("tool2"))
      .then(F::afterLlm).then(F::toolRun).then(F::toolRun).then(F::loopTop)
      .then(F::provider("text")).then(F::afterLlm)
      .expect(F::l.result == "ok" and F::refinesTurn and F::inheritsTurnInvariants)

  run reachCancelMidToolsTest =
    F::init.then(F::startStep(false)).then(F::loopTop).then(F::provider("tool2"))
      .then(F::afterLlm).then(F::toolRun).then(F::cancel)
      .expect(F::l.result == "cancelled" and F::refinesTurn and F::inheritsTurnInvariants)

  // #607: a crash is closed by the boundary.
  run reachCrashClosedTest =
    F::init.then(F::startStep(false)).then(F::loopTop).then(F::provider("badArgs"))
      .then(F::afterLlm)
      .expect(F::l.result == "crash" and F::refinesTurn and F::inheritsTurnInvariants)

  // #610: the safety cap closes with an announced error.
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
