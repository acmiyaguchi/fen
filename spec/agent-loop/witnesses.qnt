// Deterministic witnesses (quint test). Each w<issue>...Test replays the
// shortest known counterexample for that issue against `current`; each
// reach...Test shows a `fixed` behaviour the invariants rely on is reachable.
module witnesses {
  import agentloop(FIXES = Set(),
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")) as C from "./model"
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"),
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")) as F from "./model"
  import currentRefines as CR from "./model"
  import fixedRefines as FR from "./model"

  // #606: a :length reply carrying a tool call takes the natural-stop path,
  // leaving the call unanswered in history.
  run w606LengthCallUnpairedTest =
    C::init.then(C::startStep(false)).then(C::loopTop)
      .then(C::provider("lengthCall", false, false)).then(C::afterLlm)
      .expect(not(C::historyValidWhenIdle))

  // #607: malformed edit arguments crash the step after the assistant is
  // appended; nothing pairs the call.
  run w607BadArgsCrashUnpairedTest =
    C::init.then(C::startStep(false)).then(C::loopTop)
      .then(C::provider("badArgs", false, false)).then(C::afterLlm)
      .expect(C::s.result == "crash" and not(C::historyValidWhenIdle))

  // #608: an empty queued follow-up makes the loop continue, so the next
  // request ends on the assistant's own reply.
  run w608EmptyFollowUpContinuesTest =
    C::init.then(C::startStep(false)).then(C::enqueue(false, true)).then(C::loopTop)
      .then(C::provider("text", false, false)).then(C::afterLlm)
      .then(C::loopTop).then(C::provider("text", false, false))
      .expect(not(C::requestsEndOnUserSide))

  // #609: two refused tool turns end the step with an error, but the
  // lifecycle status, inferred from the last message, is ok.
  run w609RefusedTwiceReportsOkTest =
    C::init.then(C::startStep(true)).then(C::loopTop)
      .then(C::provider("tool1", false, false)).then(C::afterLlm)
      .then(C::loopTop).then(C::provider("tool1", false, false)).then(C::afterLlm)
      .expect(C::s.result == "error" and not(C::statusMatchesResult))


  // #610: the safety cap ends the step with an error but emits no :error.
  run w610SafetyCapSilentTest =
    C::init.then(C::startStep(false))
      .then(C::loopTop).then(C::provider("tool1", false, false)).then(C::afterLlm)
      .then(C::toolStart).then(C::toolExec(true)).then(C::toolNext)
      .then(C::loopTop).then(C::provider("tool1", false, false)).then(C::afterLlm)
      .then(C::toolStart).then(C::toolExec(true)).then(C::toolNext)
      .then(C::loopTop).then(C::provider("tool1", false, false)).then(C::afterLlm)
      .then(C::toolStart).then(C::toolExec(true)).then(C::toolNext)
      .then(C::loopTop)
      .expect(C::s.result == "error" and not(C::errorSignalled))

  // ---- reachability of the fixed design ----

  // A step completes normally.
  run reachCompleteTest =
    F::init.then(F::startStep(false)).then(F::loopTop)
      .then(F::provider("text", false, false)).then(F::afterLlm)
      .expect(F::s.pc == "idle" and F::s.result == "ok" and F::allInvariants)

  // A cancel mid serial tool round is closed by the boundary.
  run reachCancelMidToolsTest =
    F::init.then(F::startStep(false)).then(F::loopTop)
      .then(F::provider("tool2", false, false)).then(F::afterLlm)
      .then(F::toolStart).then(F::cancel)
      .expect(F::s.result == "cancelled" and F::allInvariants)

  // A crash (malformed arguments) is closed by the boundary too.
  run reachCrashClosedTest =
    F::init.then(F::startStep(false)).then(F::loopTop)
      .then(F::provider("badArgs", false, false)).then(F::afterLlm)
      .expect(F::s.result == "crash" and F::allInvariants)

  // A :length reply with a tool call runs its tool (dispatch on content).
  run reachLengthCallRunsToolTest =
    F::init.then(F::startStep(false)).then(F::loopTop)
      .then(F::provider("lengthCall", false, false)).then(F::afterLlm)
      .expect(F::s.pc == "tools" and F::allInvariants)

  // ---- the same bugs as refinement failures: a concrete step that is no
  // step of the abstract close-turn spec ----

  // #606: the turn closes with a call still open.
  run w606RefinementTest =
    CR::init.then(CR::mStartStep(false)).then(CR::mLoopTop)
      .then(CR::mProvider("lengthCall")).then(CR::mAfterLlm)
      .expect(not(CR::refinesTurn) and not(CR::inheritsTurnInvariants))

  // #607: a crash closes the turn with a call still open.
  run w607RefinementTest =
    CR::init.then(CR::mStartStep(false)).then(CR::mLoopTop)
      .then(CR::mProvider("badArgs")).then(CR::mAfterLlm)
      .expect(not(CR::refinesTurn))

  // #608: the model is asked for a reply it is not owed.
  run w608RefinementTest =
    CR::init.then(CR::mStartStep(false)).then(CR::mEnqueue(false, true)).then(CR::mLoopTop)
      .then(CR::mProvider("text")).then(CR::mAfterLlm)
      .then(CR::mLoopTop).then(CR::mProvider("text"))
      .expect(not(CR::refinesTurn))

  // #609: a refused turn closes "ok" while the model is still owed a reply.
  run w609RefinementTest =
    CR::init.then(CR::mStartStep(true)).then(CR::mLoopTop)
      .then(CR::mProvider("tool1")).then(CR::mAfterLlm)
      .then(CR::mLoopTop).then(CR::mProvider("tool1")).then(CR::mAfterLlm)
      .expect(not(CR::refinesTurn))

  // #610: the safety cap closes "ok" after tool results.
  run w610RefinementTest =
    CR::init.then(CR::mStartStep(false))
      .then(CR::mLoopTop).then(CR::mProvider("tool1")).then(CR::mAfterLlm)
      .then(CR::mToolStart).then(CR::mToolExec).then(CR::mToolNext)
      .then(CR::mLoopTop).then(CR::mProvider("tool1")).then(CR::mAfterLlm)
      .then(CR::mToolStart).then(CR::mToolExec).then(CR::mToolNext)
      .then(CR::mLoopTop).then(CR::mProvider("tool1")).then(CR::mAfterLlm)
      .then(CR::mToolStart).then(CR::mToolExec).then(CR::mToolNext)
      .then(CR::mLoopTop)
      .expect(not(CR::refinesTurn))

  // The fixed loop refines the spec through a tool round, a cancel, a crash.
  run reachRefinesToolRoundTest =
    FR::init.then(FR::mStartStep(false)).then(FR::mLoopTop)
      .then(FR::mProvider("tool1")).then(FR::mAfterLlm)
      .then(FR::mToolStart).then(FR::mToolExec).then(FR::mToolNext)
      .then(FR::mLoopTop).then(FR::mProvider("text")).then(FR::mAfterLlm)
      .expect(FR::refinesTurn and FR::inheritsTurnInvariants and FR::stepResult == "ok")

  run reachRefinesCancelTest =
    FR::init.then(FR::mStartStep(false)).then(FR::mLoopTop)
      .then(FR::mProvider("tool2")).then(FR::mAfterLlm)
      .then(FR::mToolStart).then(FR::mCancel)
      .expect(FR::refinesTurn and FR::stepResult == "cancelled")

  run reachRefinesCrashTest =
    FR::init.then(FR::mStartStep(false)).then(FR::mLoopTop)
      .then(FR::mProvider("badArgs")).then(FR::mAfterLlm)
      .expect(FR::refinesTurn and FR::stepResult == "crash")

  // #606 again: the next request carries the unanswered call.
  run w606NextRequestInvalidTest =
    C::init.then(C::startStep(false)).then(C::loopTop)
      .then(C::provider("lengthCall", false, false)).then(C::afterLlm)
      .then(C::startStep(false)).then(C::loopTop).then(C::provider("text", false, false))
      .expect(not(C::providerValidRequests))

  // #608 again: an empty follow-up resets the refusal allowance.
  run w608EmptyLineResetsRefusalsTest =
    C::init.then(C::startStep(true)).then(C::loopTop)
      .then(C::provider("tool1", false, false)).then(C::afterLlm)
      .then(C::loopTop).then(C::provider("text", false, false))
      .then(C::enqueue(false, true)).then(C::afterLlm)
      .expect(not(C::refusalCountsSinceInput))
}
