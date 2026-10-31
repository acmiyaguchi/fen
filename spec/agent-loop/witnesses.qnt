// Deterministic witnesses (quint test). Today's loop (`current`) carries the
// #606-#610 fixes, so each reach<issue>...Test replays the trace that once
// broke the invariant and expects it to hold now; the other reach...Tests show
// the behaviours the invariants rely on are reachable.
module witnesses {
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"),
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")) as F from "./model"
  import fixedRefines as FR from "./model"

  // #606: a :length reply carrying a tool call takes the natural-stop path,
  // leaving the call unanswered in history.
  run reach606LengthCallPairedTest =
    F::init.then(F::startStep(false)).then(F::loopTop)
      .then(F::provider("lengthCall", false, false)).then(F::afterLlm)
      .expect(F::s.pc == "tools" and F::historyValidWhenIdle)

  // #607: malformed edit arguments crash the step after the assistant is
  // appended; nothing pairs the call.
  run reach607BadArgsCrashPairedTest =
    F::init.then(F::startStep(false)).then(F::loopTop)
      .then(F::provider("badArgs", false, false)).then(F::afterLlm)
      .expect(F::s.result == "crash" and F::historyValidWhenIdle)

  // #608: an empty queued follow-up appends nothing, so the step ends instead
  // of asking again on the assistant's own reply.
  run reach608EmptyFollowUpEndsStepTest =
    F::init.then(F::startStep(false)).then(F::enqueue(false, true)).then(F::loopTop)
      .then(F::provider("text", false, false)).then(F::afterLlm)
      .expect(F::s.pc == "idle" and F::s.result == "ok" and F::requestsEndOnUserSide)

  // #609: two refused tool turns end the step with an error, but the
  // lifecycle status, inferred from the last message, is ok.
  run reach609RefusedTwiceReportsErrorTest =
    F::init.then(F::startStep(true)).then(F::loopTop)
      .then(F::provider("tool1", false, false)).then(F::afterLlm)
      .then(F::loopTop).then(F::provider("tool1", false, false)).then(F::afterLlm)
      .expect(F::s.result == "error" and F::statusMatchesResult)


  // #610: the safety cap ends the step with an error but emits no :error.
  run reach610SafetyCapAnnouncedTest =
    F::init.then(F::startStep(false))
      .then(F::loopTop).then(F::provider("tool1", false, false)).then(F::afterLlm)
      .then(F::toolStart).then(F::toolExec(true)).then(F::toolNext)
      .then(F::loopTop).then(F::provider("tool1", false, false)).then(F::afterLlm)
      .then(F::toolStart).then(F::toolExec(true)).then(F::toolNext)
      .then(F::loopTop).then(F::provider("tool1", false, false)).then(F::afterLlm)
      .then(F::toolStart).then(F::toolExec(true)).then(F::toolNext)
      .then(F::loopTop)
      .expect(F::s.result == "error" and F::errorSignalled)

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
  run reach606RefinementTest =
    FR::init.then(FR::mStartStep(false)).then(FR::mLoopTop)
      .then(FR::mProvider("lengthCall")).then(FR::mAfterLlm)
      .expect(FR::refinesTurn and FR::inheritsTurnInvariants)

  // #607: a crash closes the turn with a call still open.
  run reach607RefinementTest =
    FR::init.then(FR::mStartStep(false)).then(FR::mLoopTop)
      .then(FR::mProvider("badArgs")).then(FR::mAfterLlm)
      .expect(FR::refinesTurn)

  // #608: the model is not asked for a reply it is not owed.
  run reach608RefinementTest =
    FR::init.then(FR::mStartStep(false)).then(FR::mEnqueue(false, true)).then(FR::mLoopTop)
      .then(FR::mProvider("text")).then(FR::mAfterLlm)
      .expect(FR::refinesTurn and FR::stepResult == "ok")

  // #609: a refused turn closes "ok" while the model is still owed a reply.
  run reach609RefinementTest =
    FR::init.then(FR::mStartStep(true)).then(FR::mLoopTop)
      .then(FR::mProvider("tool1")).then(FR::mAfterLlm)
      .then(FR::mLoopTop).then(FR::mProvider("tool1")).then(FR::mAfterLlm)
      .expect(FR::refinesTurn)

  // #610: the safety cap closes "ok" after tool results.
  run reach610RefinementTest =
    FR::init.then(FR::mStartStep(false))
      .then(FR::mLoopTop).then(FR::mProvider("tool1")).then(FR::mAfterLlm)
      .then(FR::mToolStart).then(FR::mToolExec).then(FR::mToolNext)
      .then(FR::mLoopTop).then(FR::mProvider("tool1")).then(FR::mAfterLlm)
      .then(FR::mToolStart).then(FR::mToolExec).then(FR::mToolNext)
      .then(FR::mLoopTop).then(FR::mProvider("tool1")).then(FR::mAfterLlm)
      .then(FR::mToolStart).then(FR::mToolExec).then(FR::mToolNext)
      .then(FR::mLoopTop)
      .expect(FR::refinesTurn)

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

  // #606 again: the :length reply's call is answered before the next request.
  run reach606NextRequestValidTest =
    F::init.then(F::startStep(false)).then(F::loopTop)
      .then(F::provider("lengthCall", false, false)).then(F::afterLlm)
      .then(F::toolStart).then(F::toolExec(true)).then(F::toolNext)
      .then(F::loopTop).then(F::provider("text", false, false))
      .expect(F::providerValidRequests)

  // #608 again: an empty follow-up resets the refusal allowance.
  run reach608EmptyLineKeepsRefusalsTest =
    F::init.then(F::startStep(true)).then(F::loopTop)
      .then(F::provider("tool1", false, false)).then(F::afterLlm)
      .then(F::loopTop).then(F::provider("text", false, false))
      .then(F::enqueue(false, true)).then(F::afterLlm)
      .expect(F::refusalCountsSinceInput)
}
