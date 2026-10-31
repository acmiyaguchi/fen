// Proof model for the presenters' outcome contract: every consumer of a
// finished agent step reports the same outcome. Instead of re-running
// retries and tool loops per property (as spec/presenters/model.qnt does),
// `init` picks one point of a small finite input space and each consumer's
// output is a pure function of it, mirroring the code. `step` stutters, so a
// depth-0 check covers every input: the check is exhaustive, not sampled.
//
// Outcome alphabet (how one agent step ends, agent.step / step-loop):
//   ok        natural stop with model text
//   error     provider error after streaming
//   quota     provider error with error-details (usage_limit_reached)
//   cap       the tool-call safety cap: last message is a tool result
//   refused   two refused tool turns under :tool-choice :none
//   cancelled cancel at a yield: aborted assistant, :cancelled
//
// Consumers (each a fold over the step's messages or its lifecycle event):
//   json / print  turn_result.failed? + sum-usage over ALL agent.messages
//   session send  turn_result over the turn's suffix; status from lifecycle
//   rpc child     finish!: result + `exit done` unless the turn threw
//   goal          lifecycle status -> on-turn-complete -> goal_headless
//   lifecycle     turn_lifecycle.complete-event (status from last message)
//
// Fixes, by issue: "619" json usage over the suffix; "632" rpc exits failed;
// "633" goal clears last-result on failure; "634" lifecycle reports the
// step's outcome.
module outcome {
  const FIXES: Set[str]

  pure val ENDS = Set("ok", "error", "quota", "cap", "refused", "cancelled")
  pure val MARKERS = Set("continue", "done", "none")
  pure val MAX_ITERATIONS = 2
  pure val STEP_USAGE = 1    // tokens of this step's assistants
  pure val REPLAY_USAGE = 5  // tokens of a --continue replayed turn

  // ---- inputs, fixed by init ----
  var end: str        // how this step ended
  var replayed: bool  // --continue replayed an earlier turn first
  var iteration: int  // goal iteration of this step (1 or 2; 2 follows an ok "continue")
  var marker: str     // GOAL_STATUS marker in an ok step's text

  action initWith(e: str, r: bool, it: int, mk: str): bool = all {
    end' = e, replayed' = r, iteration' = it, marker' = mk,
  }

  action init = {
    nondet e = ENDS.oneOf()
    nondet r = Bool.oneOf()
    nondet it = 1.to(MAX_ITERATIONS).oneOf()
    nondet mk = MARKERS.oneOf()
    initWith(e, r, it, mk)
  }

  action step = all {
    end' = end, replayed' = replayed, iteration' = iteration, marker' = marker,
  }

  // ---- what the step left in agent.messages ----
  // stop reason of the last assistant: stop | error | tooluse | aborted
  val lastStop: str =
    if (end == "ok") "stop"
    else if (end == "error" or end == "quota") "error"
    else if (end == "cancelled") "aborted"
    else "tooluse"
  // the last message is a tool result after the cap and after refusals
  val lastIsTool: bool = end == "cap" or end == "refused"

  // ---- reference outcome ----
  val refStatus: str =
    if (end == "ok") "ok" else if (end == "cancelled") "cancelled" else "error"
  val refExit: int = if (refStatus == "ok") 0 else 1
  val refFinal: str = if (refStatus == "ok") "answer" else "none"
  val refDetails: bool = end == "quota"
  val refUsage: int = STEP_USAGE

  // ---- consumers ----
  // turn_result.failed? over the last assistant
  val failed: bool = Set("error", "tooluse", "aborted").contains(lastStop)

  // turn_lifecycle.complete-event
  val lifecycleStatus: str =
    if (FIXES.contains("634")) refStatus
    else if (lastStop == "aborted" and not(lastIsTool)) "cancelled"
    else if (lastStop == "error" and not(lastIsTool)) "error"
    else "ok"

  // json / print
  val jsonExit: int = if (failed) 1 else 0
  val jsonFinal: str = if (failed) "none" else "answer"
  val jsonUsage: int =
    if (FIXES.contains("619") or not(replayed)) STEP_USAGE
    else STEP_USAGE + REPLAY_USAGE
  val jsonDetails: bool = failed and end == "quota"

  // session send
  val sendExit: int = if (failed) 1 else 0
  val sendStatus: str = if (failed) "error" else lifecycleStatus

  // rpc child: a wire cancel exits cancelled with no result
  val rpcExit: int =
    if (end == "cancelled") 1
    else if (FIXES.contains("632") and failed) 1
    else 0
  // final-text: types.assistant-text of the last assistant
  val rpcFinal: str =
    if (end == "cancelled" or (FIXES.contains("632") and failed)) "none"
    else if (lastStop == "error") "blob"           // "[error] ..." block
    else if (lastStop == "tooluse") "toolText"     // the tool-use turn's text
    else "answer"

  // goal: on-turn-complete with the lifecycle status; handle-success! sets
  // last-result to the step's return value and follows the marker.
  // An iteration-2 step follows an ok "continue" iteration, so last-result
  // already holds that iteration's text ("prev").
  val stepResult: str = if (end == "ok") "answer" else "blob"
  val stepMarker: str = if (end == "ok") marker else "none"
  val goalStatus: str =
    if (lifecycleStatus == "cancelled") "stopped"
    else if (lifecycleStatus == "error") "error"
    else if (stepMarker == "none") "blocked"
    else if (stepMarker == "done") "done"
    else if (iteration >= MAX_ITERATIONS) "cap-reached"
    else "running"
  val goalResult: str =
    if (lifecycleStatus == "ok") stepResult
    else if (FIXES.contains("633")) "none"
    else if (iteration > 1) "prev"
    else "none"
  val goalTerminal: bool = goalStatus != "running"
  pure def goalExitOf(s: str): int =
    if (s == "done") 0 else if (s == "error") 1 else 2
  // documented mapping (docs/sessions.md): failures exit 1
  val goalExpected: str =
    if (end == "ok")
      (if (marker == "done") "done" else if (marker == "none") "blocked" else "cap-reached")
    else if (end == "cancelled") "stopped"
    else "error"

  // ---- properties (names as in spec/presenters/model.qnt) ----
  val headlessExitMatchesStatus = jsonExit == refExit and sendExit == refExit
  val headlessFinalTextMatches = jsonFinal == refFinal
  val headlessErrorDetailsMatch = jsonDetails == refDetails
  val headlessUsageIsTurnUsage = jsonUsage == refUsage
  val sendStatusMatchesOutcome =
    sendStatus == refStatus or (refStatus == "cancelled" and sendStatus == "error")
  val lifecycleStatusMatchesOutcome = lifecycleStatus == refStatus
  val rpcExitMatchesStatus = rpcExit == refExit
  val rpcFinalTextMatches = rpcFinal == refFinal
  val goalFinalTextMatches = goalTerminal implies goalResult == refFinal
  val goalExitMatches = goalTerminal implies goalExitOf(goalStatus) == goalExitOf(goalExpected)

  val allInvariants = and {
    headlessExitMatchesStatus, headlessFinalTextMatches, headlessErrorDetailsMatch,
    headlessUsageIsTurnUsage, sendStatusMatchesOutcome, lifecycleStatusMatchesOutcome,
    rpcExitMatchesStatus, rpcFinalTextMatches, goalFinalTextMatches, goalExitMatches,
  }
}

module current { import outcome(FIXES = Set()).* }
module fixed { import outcome(FIXES = Set("619", "632", "633", "634")).* }
module fix634 { import outcome(FIXES = Set("634")).* }
