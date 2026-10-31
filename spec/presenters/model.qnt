// Model of fen's non-TUI presenters: every consumer of the agent event stream
// other than the TUI, and the outcome each one reports.
//
// One shared stream comes from the agent (agent.step / step-loop):
//   llm-start, text deltas, provider-retry, llm-end, then
//     natural stop: assistant-stream-end            (step returns the text)
//     provider error: :error                        (assistant :error appended)
//     tool use: stream-end {:final? false}, tool rows, next provider call;
//       at the safety cap the step ends silently with "[error] ..." (#610);
//       under :tool-choice :none a second refusal ends it with :error
//     cancel at a yield: aborted assistant, :cancelled
// After the step, turn_lifecycle emits :agent-turn-complete with a status
// guessed from the LAST message (#609).
//
// The reference fold (refStatus / refFinal / refUsage / refDetails / refExit)
// is the outcome every presenter is supposed to report. Each presenter's
// actual fold mirrors its code:
//   json / print   extensions/adapters/presenters/{json,print}/init.fnl
//                  (turn_result.failed? over ALL agent messages, incl. replay)
//   session send   packages/fen/src/fen/session_control.fnl run-turn!
//                  (turn_result over the turn's message suffix)
//   rpc child      extensions/adapters/presenters/rpc/init.fnl finish!
//                  (result + `exit done` after any turn that did not throw)
//   goal headless  extensions/behaviors/companions/goal/init.fnl on-turn-complete
//                  + extensions/adapters/presenters/goal_headless/init.fnl
//   web            extensions/adapters/presenters/web/ingest.fnl
//   stdio          extensions/adapters/presenters/stdio/init.fnl render-event
// FIXED selects the candidate fixes so the same invariants can be checked.
module presenters {
  const FIXED: bool

  pure val MAX_STEPS = 2      // goal iterations (goal --max-iterations 2)
  pure val SAFETY = 2         // provider calls per step before the cap
  pure val MAX_ATTEMPTS = 2   // provider attempts per call
  pure val REPLY_LEN = 2      // tokens per complete reply

  type Tok = { step: int, call: int, attempt: int, idx: int }
  // role: user | assistant | tool ; stop: stop | tooluse | error | aborted | ""
  type Msg = { role: str, stop: str, toks: List[Tok], usage: int, details: bool }

  type Event =
    | User
    | Delta(Tok)
    | Retry
    | StreamEnd
    | ErrorEv
    | CancelledEv
    | ToolRow

  type Row = { kind: str, toks: List[Tok] }
  // web transcript + its open streaming row; stdio lines + open "ai>" line
  type Disp = { web: List[Row], webOpen: int, stdio: List[Row], stdioOpen: bool }

  // A reported final text: absent, model text, or an "[error] ..." blob.
  type Text = { has: bool, toks: List[Tok], blob: bool }

  type Goal = {
    status: str,          // none | running | done | blocked | error | stopped | cap-reached
    result: Text,         // goal-state.last-result
    lastFinal: Text,      // reference final text of the last finished step
    lastEnd: str,         // how the last step really ended
    lastMarker: str,      // GOAL_STATUS marker the model wrote (continue | done | none)
  }

  pure val NO_TEXT: Text = { has: false, toks: [], blob: false }
  pure val NO_MSG: Msg = { role: "", stop: "", toks: [], usage: 0, details: false }

  // ---- display folds ----
  pure def barrier(r: Row): bool =
    r.kind == "user" or r.kind == "tool" or r.kind == "assistant"

  pure def webDelta(d: Disp, tok: Tok): Disp =
    // find-streaming-row: walk back from the end; closed assistant, tool and
    // user rows stop the search; retry/error/cancelled rows do not.
    val reachable = d.webOpen >= 0 and
      d.web.indices().forall(i => i > d.webOpen implies not(barrier(d.web[i])))
    if (reachable)
      { ...d, web: d.web.replaceAt(d.webOpen,
                 { ...d.web[d.webOpen], toks: d.web[d.webOpen].toks.append(tok) }) }
    else
      { ...d, web: d.web.append({ kind: "assistant", toks: [tok] }), webOpen: d.web.length() }

  pure def webClose(d: Disp): Disp = { ...d, webOpen: -1 }
  pure def webPush(d: Disp, k: str): Disp =
    { ...d, web: d.web.append({ kind: k, toks: [] }) }

  pure def stdioClose(d: Disp): Disp = { ...d, stdioOpen: false }
  pure def stdioPush(d: Disp, k: str): Disp =
    { ...d, stdio: d.stdio.append({ kind: k, toks: [] }), stdioOpen: false }
  pure def stdioDelta(d: Disp, tok: Tok): Disp =
    if (d.stdioOpen)
      { ...d, stdio: d.stdio.replaceAt(d.stdio.length() - 1,
                { ...d.stdio[d.stdio.length() - 1],
                  toks: d.stdio[d.stdio.length() - 1].toks.append(tok) }) }
    else
      { ...d, stdio: d.stdio.append({ kind: "ai", toks: [tok] }), stdioOpen: true }

  pure def show(d: Disp, e: Event): Disp = match e {
    | User => d.webPush("user").stdioPush("you")
    | Delta(tok) => d.webDelta(tok).stdioDelta(tok)
    | Retry =>
        // web: generic row, open row kept (FIXED: superseded text dropped);
        // stdio: finish-stream! then "info> provider retry"
        val w = if (FIXED and d.webOpen >= 0)
                  { ...d, web: d.web.replaceAt(d.webOpen, { ...d.web[d.webOpen], toks: [] }) }
                else d
        w.webPush("retry").stdioPush("retry")
    | StreamEnd => d.webClose().stdioClose()
    | ErrorEv =>
        // web leaves the open row streaming (FIXED closes it); stdio closes.
        (if (FIXED) d.webClose() else d).webPush("error").stdioPush("err")
    | CancelledEv => (if (FIXED) d.webClose() else d).webPush("cancelled").stdioPush("info")
    | ToolRow => d.webPush("tool").stdioPush("tool")
  }

  pure def showAll(d: Disp, es: List[Event]): Disp = es.foldl(d, (acc, e) => show(acc, e))

  // ---- message helpers (turn_result.fnl) ----
  pure def lastAssistant(h: List[Msg]): Msg =
    h.foldl(NO_MSG, (acc, m) => if (m.role == "assistant") m else acc)
  pure def hasAssistant(h: List[Msg]): bool = h.foldl(false, (acc, m) => acc or m.role == "assistant")
  pure def turnFailed(h: List[Msg]): bool =
    not(hasAssistant(h)) or Set("error", "tooluse", "aborted").contains(lastAssistant(h).stop)
  pure def sumUsage(h: List[Msg]): int =
    h.foldl(0, (acc, m) => if (m.role == "assistant") acc + m.usage else acc)

  // ---- state ----
  var phase: str          // idle | streaming | ended | over
  var iter: int
  var calls: int
  var attempt: int
  var buf: List[Tok]
  var hist: List[Msg]     // agent.messages (incl. --continue replay)
  var stepStart: int      // first index of this step's messages
  var stepEnd: str        // ok | error | cap | refused | cancelled
  var disp: Disp
  var goal: Goal
  var lastAction: str

  action init = {
    nondet replayed = Bool.oneOf()
    val h0: List[Msg] =
      if (replayed)
        [ { role: "user", stop: "", toks: [], usage: 0, details: false },
          { role: "assistant", stop: "stop",
            toks: [{ step: 0, call: 1, attempt: 1, idx: 0 }], usage: 5, details: false } ]
      else []
    all {
      phase' = "idle", iter' = 0, calls' = 0, attempt' = 0, buf' = [],
      hist' = h0, stepStart' = h0.length(), stepEnd' = "",
      disp' = { web: [], webOpen: -1, stdio: [], stdioOpen: false },
      goal' = { status: "none", result: NO_TEXT, lastFinal: NO_TEXT, lastEnd: "", lastMarker: "" },
      lastAction' = "init",
    }
  }

  // A typed prompt (step 1) or the next goal iteration (emit-user? false).
  action startStep = all {
    phase == "idle", iter < MAX_STEPS,
    iter == 0 or goal.status == "running",
    phase' = "streaming", iter' = iter + 1, calls' = 1, attempt' = 1, buf' = [],
    hist' = hist.append({ role: "user", stop: "", toks: [], usage: 0, details: false }),
    stepStart' = hist.length(), stepEnd' = "",
    disp' = if (iter == 0) disp.show(User) else disp,
    goal' = if (iter == 0) { ...goal, status: "running" } else goal,
    lastAction' = "startStep",
  }

  action streamToken = all {
    phase == "streaming", buf.length() < REPLY_LEN,
    val tok = { step: iter, call: calls, attempt: attempt, idx: buf.length() }
    all {
      buf' = buf.append(tok), disp' = disp.show(Delta(tok)),
      phase' = phase, iter' = iter, calls' = calls, attempt' = attempt,
      hist' = hist, stepStart' = stepStart, stepEnd' = stepEnd, goal' = goal,
      lastAction' = "streamToken",
    }
  }

  // Transient failure with attempts left: :provider-retry, back off, retry.
  action retry = all {
    phase == "streaming", attempt < MAX_ATTEMPTS,
    attempt' = attempt + 1, buf' = [], disp' = disp.show(Retry),
    phase' = phase, iter' = iter, calls' = calls, hist' = hist,
    stepStart' = stepStart, stepEnd' = stepEnd, goal' = goal,
    lastAction' = "retry",
  }

  action endStop = all {
    phase == "streaming", buf.length() == REPLY_LEN,
    hist' = hist.append({ role: "assistant", stop: "stop", toks: buf, usage: 1, details: false }),
    disp' = disp.show(StreamEnd),
    phase' = "ended", stepEnd' = "ok",
    iter' = iter, calls' = calls, attempt' = attempt, buf' = buf,
    stepStart' = stepStart, goal' = goal, lastAction' = "endStop",
  }

  // Permanent provider error (incl. quota exhaustion with error-details).
  // The assistant's content is the "[error] ..." text block (types.assistant-error).
  action endError(details: bool): bool = all {
    phase == "streaming",
    hist' = hist.append({ role: "assistant", stop: "error", toks: [], usage: 1, details: details }),
    disp' = disp.show(ErrorEv),
    phase' = "ended", stepEnd' = "error",
    iter' = iter, calls' = calls, attempt' = attempt, buf' = buf,
    stepStart' = stepStart, goal' = goal, lastAction' = "endError",
  }

  // Tool use. Below the cap the loop runs the tool and calls again; at the
  // cap the step ends silently (cap) or, under :tool-choice :none, with an
  // :error after the second refusal (refused).
  action endToolUse(refused: bool): bool = all {
    phase == "streaming", buf.length() == REPLY_LEN,
    val h1 = hist.append({ role: "assistant", stop: "tooluse", toks: buf, usage: 1, details: false })
                 .append({ role: "tool", stop: "", toks: [], usage: 0, details: false })
    val d1 = disp.showAll([StreamEnd, ToolRow])
    all {
      hist' = h1,
      if (calls < SAFETY)
        all { phase' = "streaming", calls' = calls + 1, attempt' = 1, buf' = [],
              disp' = d1, stepEnd' = stepEnd }
      else
        all { phase' = "ended", calls' = calls, attempt' = attempt, buf' = buf,
              disp' = if (refused) d1.show(ErrorEv) else d1,
              stepEnd' = if (refused) "refused" else "cap" },
      iter' = iter, stepStart' = stepStart, goal' = goal,
      lastAction' = if (calls < SAFETY) "endToolUse" else if (refused) "endRefused" else "endCap",
    }
  }

  // SIGINT-equivalent cancel / wire cancel / deadline at a cooperative yield.
  action cancel = all {
    phase == "streaming",
    hist' = hist.append({ role: "assistant", stop: "aborted", toks: [], usage: 0, details: false }),
    disp' = disp.show(CancelledEv),
    phase' = "ended", stepEnd' = "cancelled",
    iter' = iter, calls' = calls, attempt' = attempt, buf' = buf,
    stepStart' = stepStart, goal' = goal, lastAction' = "cancel",
  }

  // ---- reference outcome of the step that just ended ----
  val stepMsgs: List[Msg] = hist.slice(stepStart, hist.length())
  val refStatus: str =
    if (stepEnd == "ok") "ok" else if (stepEnd == "cancelled") "cancelled" else "error"
  val refFinal: Text =
    if (refStatus == "ok") { has: true, toks: lastAssistant(stepMsgs).toks, blob: false }
    else NO_TEXT
  val refUsage: int = sumUsage(stepMsgs)
  val refDetails: bool = stepEnd == "error" and lastAssistant(stepMsgs).details
  val refExit: int = if (refStatus == "ok") 0 else 1

  // turn_lifecycle.complete-event: status from the last message (#609).
  val lifecycleStatus: str =
    if (FIXED) refStatus
    else
      val last = hist[hist.length() - 1]
      if (last.stop == "aborted") "cancelled"
      else if (last.role == "assistant" and last.stop == "error") "error"
      else "ok"

  // What agent.step returns, as goal sees it in ev.result.
  val stepResult: Text =
    if (stepEnd == "ok") { has: true, toks: lastAssistant(stepMsgs).toks, blob: false }
    else { has: true, toks: [], blob: true }   // "[error] ..." / "[cancelled]"

  // After the step: :agent-turn-complete goes to the goal companion.
  action finishStep(marker: str): bool = all {
    phase == "ended",
    val ls = lifecycleStatus
    val isText = stepEnd == "ok"
    val mk = if (ls == "ok" and isText) marker else "none"
    val g0 = { ...goal, lastFinal: refFinal, lastEnd: stepEnd, lastMarker: mk }
    val g1 =
      if (ls == "cancelled")
        { ...g0, status: "stopped", result: if (FIXED) NO_TEXT else goal.result }
      else if (ls == "error")
        { ...g0, status: "error", result: if (FIXED) NO_TEXT else goal.result }
      else
        // handle-success!: last-result := ev.result, then the marker decides
        val g2 = { ...g0, result: stepResult }
        if (mk == "none") { ...g2, status: "blocked" }
        else if (mk == "done") { ...g2, status: "done" }
        else if (iter >= MAX_STEPS) { ...g2, status: "cap-reached" }
        else { ...g2, status: "running" }
    all {
      goal' = g1,
      phase' = if (g1.status == "running") "idle" else "over",
      iter' = iter, calls' = calls, attempt' = attempt, buf' = buf, hist' = hist,
      stepStart' = stepStart, stepEnd' = stepEnd, disp' = disp,
      lastAction' = "finishStep",
    }
  }

  action step = any {
    startStep,
    streamToken,
    retry,
    endStop,
    nondet dt = Bool.oneOf()
    endError(dt),
    nondet rf = Bool.oneOf()
    endToolUse(rf),
    cancel,
    nondet mk = Set("continue", "done").oneOf()
    finishStep(mk),
  }

  // ---- presenter folds over the finished step ----
  // json / print: turn_result over ALL agent messages.
  val jsonFailed: bool = turnFailed(hist)
  val jsonExit: int = if (jsonFailed) 1 else 0
  val jsonFinal: Text =
    if (jsonFailed) NO_TEXT else { has: true, toks: lastAssistant(hist).toks, blob: false }
  val jsonUsage: int = if (FIXED) refUsage else sumUsage(hist)
  val jsonDetails: bool = jsonFailed and lastAssistant(hist).details
  // session send: turn_result over the turn's suffix.
  val sendFailed: bool = turnFailed(stepMsgs)
  val sendExit: int = if (sendFailed) 1 else 0
  val sendFinal: Text =
    if (sendFailed) NO_TEXT else { has: true, toks: lastAssistant(stepMsgs).toks, blob: false }
  val sendStatus: str = if (sendFailed) "error" else lifecycleStatus
  val sendDetails: bool = sendFailed and lastAssistant(stepMsgs).details
  // rpc child (prompt, turn-complete, close): finish! emits result + exit done
  // unless the turn threw; a wire cancel exits cancelled with no result.
  val rpcExit: int =
    if (stepEnd == "cancelled") 1
    else if (FIXED and sendFailed) 1
    else 0
  val rpcFinal: Text =
    val a = lastAssistant(stepMsgs)
    if (stepEnd == "cancelled" or (FIXED and sendFailed)) NO_TEXT
    else if (a.stop == "error") { has: true, toks: [], blob: true }
    else { has: a.toks.length() > 0, toks: a.toks, blob: false }

  // goal headless: status -> exit code, and the expected status from truth.
  pure def goalExitOf(s: str): int =
    if (s == "done") 0 else if (s == "error") 1 else 2
  val goalExpected: str =
    if (goal.lastEnd == "ok")
      (if (goal.lastMarker == "done") "done" else "cap-reached")
    else if (goal.lastEnd == "cancelled") "stopped"
    else "error"

  // ---- properties ----
  val headlessStep = phase == "ended" and iter == 1

  // print / json / session send exit non-zero iff the turn did not succeed.
  val headlessExitMatchesStatus =
    headlessStep implies (jsonExit == refExit and sendExit == refExit)

  val headlessFinalTextMatches =
    headlessStep implies (jsonFinal == refFinal and sendFinal == refFinal)

  val headlessErrorDetailsMatch =
    headlessStep implies (jsonDetails == refDetails and sendDetails == refDetails)

  // The usage a headless outcome reports is this turn's usage.
  val headlessUsageIsTurnUsage =
    headlessStep implies (jsonUsage == refUsage and sumUsage(stepMsgs) == refUsage)

  // session send's turn.status agrees with the reference status.
  val sendStatusMatchesOutcome =
    headlessStep implies (sendStatus == refStatus or (refStatus == "cancelled" and sendStatus == "error"))

  // :agent-turn-complete status agrees with how the step really ended.
  val lifecycleStatusMatchesOutcome = phase == "ended" implies lifecycleStatus == refStatus

  // rpc child: exit code non-zero iff the run did not succeed.
  val rpcExitMatchesStatus = headlessStep implies rpcExit == refExit

  // rpc child: result.final-text is the answer, never an error blob.
  val rpcFinalTextMatches = headlessStep implies rpcFinal == refFinal

  // goal: reported final text belongs to the last iteration.
  val goalFinalTextMatches = phase == "over" implies goal.result == goal.lastFinal

  // goal: exit code follows the documented mapping of what really happened.
  val goalExitMatches = phase == "over" implies goalExitOf(goal.status) == goalExitOf(goalExpected)

  pure def assistantRows(rs: List[Row]): List[Row] = rs.select(r => r.kind == "assistant" or r.kind == "ai")
  pure def singleAttempt(r: Row): bool =
    r.toks.foldl(true, (ok, k) => ok and k.step == r.toks[0].step and k.call == r.toks[0].call
                                      and k.attempt == r.toks[0].attempt)
  pure def singleStep(r: Row): bool =
    r.toks.foldl(true, (ok, k) => ok and k.step == r.toks[0].step)
  pure def shown(rs: List[Row], toks: List[Tok]): bool =
    assistantRows(rs).foldl(false, (f, r) => f or r.toks == toks)

  // web: no transcript row mixes two provider attempts.
  val webRowsSingleAttempt = assistantRows(disp.web).foldl(true, (ok, r) => ok and singleAttempt(r))
  // web: no row mixes two steps (prompt / goal iterations).
  val webRowsSingleStep = assistantRows(disp.web).foldl(true, (ok, r) => ok and singleStep(r))
  // web: a successful reply is shown exactly as persisted.
  val webOkReplyShown =
    (phase == "ended" and stepEnd == "ok") implies shown(disp.web, lastAssistant(hist).toks)

  // stdio: each "ai>" line comes from one attempt (retry closes the line).
  val stdioLinesSingleAttempt = assistantRows(disp.stdio).foldl(true, (ok, r) => ok and singleAttempt(r))
  val stdioOkReplyShown =
    (phase == "ended" and stepEnd == "ok") implies shown(disp.stdio, lastAssistant(hist).toks)

  val boundedCalls = calls <= SAFETY and attempt <= MAX_ATTEMPTS and iter <= MAX_STEPS

  val allInvariants = and {
    headlessExitMatchesStatus, headlessFinalTextMatches, headlessErrorDetailsMatch,
    headlessUsageIsTurnUsage, sendStatusMatchesOutcome, lifecycleStatusMatchesOutcome,
    rpcExitMatchesStatus, rpcFinalTextMatches, goalFinalTextMatches, goalExitMatches,
    webRowsSingleAttempt, webRowsSingleStep, webOkReplyShown,
    stdioLinesSingleAttempt, stdioOkReplyShown, boundedCalls,
  }
}

module current { import presenters(FIXED = false).* }
module fixed { import presenters(FIXED = true).* }
