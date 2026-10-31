// Model of fen's agent step loop (agent.step / step-loop), as it works today.
//
//   step            -> append UserMessage, run step-loop under xpcall; on
//                      CANCEL-MARKER append ONE empty :aborted assistant and
//                      emit :cancelled; any other error re-raises (the TUI's
//                      on-tick turns it into an "agent task:" :error event)
//   step-loop top   -> safety cap check; drain steering (inject non-empty
//                      lines, reset refused-turns if any were injected);
//                      emit :llm-start; yield
//   provider        -> one nondeterministic outcome (network domain covers
//                      retries): text / tool-use with 1-2 calls / error /
//                      :length that still carries a tool call / tool-use
//                      whose edit arguments are malformed
//   after llm-end   -> append assistant; yield (cancel pairs calls only if
//                      stop-reason is :tool-use)
//   dispatch        -> :error -> :error event, stop
//                      :tool-use -> :none ? refuse (2nd refusal = error)
//                                         : run-tool-calls
//                      anything else -> natural stop: poll steering, then
//                                       follow-up; continue if the drained
//                                       list was non-empty
//   run-tool-calls  -> same-turn-edit-conflicts over raw arguments, then
//                      serial calls (emit :tool-call, yield, execute, append,
//                      yield) and consecutive parallel-safe batches (launch
//                      all, children yield, results appended in order at the
//                      end); a cancel at any yield pairs every unreturned call
//
// Queues mirror extensions/behaviors/kernel/steering/service.fnl: steering
// and follow-up lines are appended while the agent is busy and drained
// one-at-a-time; a line may be "" (`>` alone strips to "").
//
// The lifecycle status mirrors packages/fen/src/fen/turn_lifecycle.fnl,
// which infers status from the last message rather than the step result.
//
// FIXED selects the candidate fixes so the same invariants can be checked
// against both.
module agentloop {
  // The pairing rule and the step outcome come from the close-turn core (#668).
  import turn.* from "../core/turn/turn"

  const FIXED: bool
  // provider outcomes the environment may produce
  const OUTCOMES: Set[str]

  pure val MAX_STEPS = 2   // user prompts
  pure val CAP = 3         // SAFETY-CAP, scaled down
  pure val MAX_LINES = 2   // queued steering/follow-up lines

  // role: "user" | "asst" | "result"
  // asst stop: "stop" | "tool" | "length" | "error" | "aborted"
  // result kind: "real" | "fail" | "cancel" | "refuse"
  type Msg = { role: str, stop: str, calls: List[int], cid: int, kind: str }
  type Line = { id: int, empty: bool }

  type S = {
    pc: str,                 // "idle" | "top" | "llm" | "post" | "tools"
    sub: str,                // tools phase: "start" | "pre" | "post" | "batch"
    history: List[Msg],      // agent.messages
    calls: List[int],        // tool calls of the latest assistant
    par: List[bool],         // parallel-safe? per call
    idx: int,                // current call index
    batchEnd: int,           // exclusive end of the running parallel batch
    batchOut: int -> str,    // finished batch children: "real" | "fail"
    badArgs: bool,           // latest assistant has malformed edit arguments
    toolNone: bool,          // step-opts {:tool-choice :none}
    refused: int,            // refused-turns
    consecRefused: int,      // ghost: refusals since the last user-side message
    iters: int,              // CAP - safety
    steps: int,
    nextCall: int,
    nextLine: int,
    steerQ: List[Line],
    followQ: List[Line],
    enqueued: List[Line],    // ghost
    injected: List[int],     // ghost: line ids appended as UserMessages
    dropped: List[int],      // ghost: drained but not appended
    tcEv: List[int],         // :tool-call events, by call id
    trEv: List[int],         // :tool-result events, by call id
    stepErr: bool,           // an :error event was emitted in this step
    result: str,             // last finished step: "none" | "ok" | "error" | "cancelled" | "crash"
    status: str,             // :agent-turn-complete status for that step
    reqOk: bool,             // ghost: every provider request had valid history
    reqNoTrailingAsst: bool, // ghost: no provider request ended on an assistant
    noneExecuted: bool,      // ghost: a :none step executed a tool
    cancels: int,            // ghost: cancelled steps
    lastAction: str,
  }

  // ---- pure helpers ----
  pure def mkUser(k: str): Msg = { role: "user", stop: "", calls: [], cid: -1, kind: k }
  pure def mkAsst(stop: str, cs: List[int]): Msg = { role: "asst", stop: stop, calls: cs, cid: -1, kind: "" }
  pure def mkResult(id: int, k: str): Msg = { role: "result", stop: "", calls: [], cid: id, kind: k }

  // agent.context-message?
  pure def inContext(m: Msg): bool =
    not(m.role == "asst" and (m.stop == "error" or (m.stop == "aborted" and m.calls.length() == 0)))

  pure def ctx(h: List[Msg]): List[Msg] = h.select(m => inContext(m))

  // The provider's view of the history, in the core's terms.
  pure def entries(h: List[Msg]): List[Entry] =
    ctx(h).foldl(NOENTRIES, (acc, m) =>
      acc.append(if (m.role == "asst") eAsst(m.calls)
                 else if (m.role == "result") eResult(m.cid)
                 else eUser))

  // Provider-valid: each assistant's tool calls are answered right after it,
  // in order, exactly once; no result without a pending call (core rule).
  pure def validCtx(h: List[Msg]): bool = turnValid(entries(h))

  pure def lastCtxRole(h: List[Msg]): str =
    val c = ctx(h)
    if (c.length() == 0) "none" else c[c.length() - 1].role

  pure def resultIds(h: List[Msg]): List[int] =
    h.select(m => m.role == "result").foldl(List(-1).tail(), (acc, m) => acc.append(m.cid))

  pure def lastMsg(s: S): Msg = s.history[s.history.length() - 1]

  pure def slice2(l: List[int], lo: int, hi: int): List[int] =
    if (lo >= hi) List(-1).tail() else l.slice(lo, hi)

  pure def appendUser(s: S, k: str): S =
    { ...s, history: s.history.append(mkUser(k)), consecRefused: 0 }

  // Synthetic results for calls[from..]; the first one already emitted its
  // :tool-call event when `emittedFirst`.
  pure def pairFrom(s: S, start: int, kind: str, emittedFirst: bool): S =
    val ids = slice2(s.calls, start, s.calls.length())
    val evIds = if (emittedFirst and ids.length() > 0) ids.tail() else ids
    { ...s,
      history: ids.foldl(s.history, (h, id) => h.append(mkResult(id, kind))),
      tcEv: s.tcEv.concat(evIds),
      trEv: s.trEv.concat(ids) }

  // FIXED: the step boundary pairs whatever the last assistant left open,
  // keyed by what is in the history (core `openCalls`), whatever the unwind
  // was. A call that never emitted :tool-call gets one with its result, as
  // append-synthetic-tool-result! does today.
  pure def closeOpen(s: S, kind: str): S =
    val ids = openCalls(entries(s.history))
    { ...s,
      history: ids.foldl(s.history, (h, id) => h.append(mkResult(id, kind))),
      tcEv: ids.foldl(s.tcEv, (t, id) =>
        if (t.foldl(false, (f, x) => f or x == id)) t else t.append(id)),
      trEv: s.trEv.concat(ids) }

  // Batch children's results, appended in original order after the batch.
  pure def batchResults(s: S): S =
    val ks = range(s.idx, s.batchEnd)
    { ...s,
      history: ks.foldl(s.history, (h, k) =>
        h.append(mkResult(s.calls[k],
          if (s.batchOut.keys().contains(k)) s.batchOut.get(k) else "cancel"))),
      trEv: ks.foldl(s.trEv, (t, k) => t.append(s.calls[k])) }

  // turn_lifecycle.complete-event (current) vs step result (fixed).
  pure def lifecycle(s: S, res: str): str =
    if (FIXED) outcomeOf(res)
    else if (res == "crash") "error"
    else
      val last = lastMsg(s)
      if (res == "cancelled" or last.stop == "aborted") "cancelled"
      else if (last.role == "asst" and last.stop == "error") "error"
      else "ok"

  pure def finish(s: S, res: str, act: str): S =
    { ...s, pc: "idle", sub: "start", result: res, status: lifecycle(s, res), lastAction: act }

  // drain one steering line; returns the new state and whether a
  // UserMessage was appended
  pure def drain(s: S, steer: bool): { s: S, appended: bool, drained: bool } =
    val q = if (steer) s.steerQ else s.followQ
    if (q.length() == 0) { s: s, appended: false, drained: false }
    else
      val line = q[0]
      val s1 = if (steer) { ...s, steerQ: q.tail() } else { ...s, followQ: q.tail() }
      if (line.empty) { s: { ...s1, dropped: s1.dropped.append(line.id) }, appended: false, drained: true }
      else
        val s2 = appendUser(s1, if (steer) "steer" else "follow")
        { s: { ...s2, injected: s2.injected.append(line.id) }, appended: true, drained: true }

  pure def toolTurn(m: Msg): bool =
    m.stop == "tool" or (FIXED and m.calls.length() > 0 and m.stop != "error")

  // first index >= i whose call is not parallel-safe
  pure def batchEndFrom(par: List[bool], i: int): int =
    range(i, par.length()).foldl({ end: par.length(), open: true }, (acc, k) =>
      if (acc.open and not(par[k])) { end: k, open: false } else acc).end

  // ---- state ----
  var s: S

  action init = s' = {
    pc: "idle", sub: "start", history: [], calls: [], par: [], idx: 0, batchEnd: 0,
    batchOut: Map(), badArgs: false, toolNone: false, refused: 0, consecRefused: 0,
    iters: 0, steps: 0, nextCall: 0, nextLine: 0, steerQ: [], followQ: [],
    enqueued: [], injected: [], dropped: [], tcEv: [], trEv: [], stepErr: false,
    result: "none", status: "none", reqOk: true, reqNoTrailingAsst: true,
    noneExecuted: false, cancels: 0, lastAction: "init",
  }

  // ---- environment: the user ----
  action startStep(none: bool): bool = all {
    s.pc == "idle", s.steps < MAX_STEPS,
    s' = { ...appendUser(s, "prompt"),
           pc: "top", steps: s.steps + 1, toolNone: none, refused: 0, iters: 0,
           stepErr: false, badArgs: false, lastAction: "startStep" },
  }

  // Lines typed while busy go to a queue (`>` prefix = follow-up).
  action enqueue(steer: bool, empty: bool): bool = all {
    s.pc != "idle", s.nextLine < MAX_LINES,
    val line = { id: s.nextLine, empty: empty }
    s' = { ...s,
           steerQ: if (steer) s.steerQ.append(line) else s.steerQ,
           followQ: if (steer) s.followQ else s.followQ.append(line),
           enqueued: s.enqueued.append(line), nextLine: s.nextLine + 1,
           lastAction: "enqueue" },
  }

  // ---- step-loop ----
  action loopTop = all {
    s.pc == "top",
    if (s.iters >= CAP)
      // safety cap: log.warn + "[error] ..." return, no :error event today
      s' = finish({ ...s, stepErr: s.stepErr or FIXED }, "error", "safetyCap")
    else
      val d = drain(s, true)
      s' = { ...d.s, pc: "llm", iters: s.iters + 1,
             refused: if (d.appended) 0 else s.refused, lastAction: "loopTop" },
  }

  // One provider request; the request carries the current history.
  action provider(outcome: str, p0: bool, p1: bool): bool = all {
    s.pc == "llm",
    val n = if (outcome == "tool2") 2
            else if (outcome == "tool1" or outcome == "lengthCall" or outcome == "badArgs") 1
            else 0
    val cs = range(s.nextCall, s.nextCall + n)
    val stop = if (outcome == "text") "stop"
               else if (outcome == "error") "error"
               else if (outcome == "lengthCall") "length"
               else "tool"
    s' = { ...s,
           reqOk: s.reqOk and validCtx(s.history),
           reqNoTrailingAsst: s.reqNoTrailingAsst and lastCtxRole(s.history) != "asst",
           history: s.history.append(mkAsst(stop, cs)),
           calls: cs, par: [p0, p1].slice(0, n),
           badArgs: outcome == "badArgs",
           nextCall: s.nextCall + n, pc: "post", lastAction: outcome },
  }

  // CANCEL-MARKER at a cooperative yield.
  action cancel = all {
    s.pc == "llm" or s.pc == "post"
      or (s.pc == "tools" and (s.sub == "pre" or s.sub == "post"
            or (s.sub == "batch" and s.batchOut.keys().size() < s.batchEnd - s.idx))),
    val paired =
      // FIXED: the batch runner still appends finished children in call
      // order; everything else is the boundary's job.
      if (FIXED)
        closeOpen(if (s.pc == "tools" and s.sub == "batch") batchResults(s) else s, "cancel")
      else if (s.pc == "post")
        if (toolTurn(lastMsg(s))) pairFrom(s, 0, "cancel", false) else s
      else if (s.pc == "tools" and s.sub == "pre") pairFrom(s, s.idx, "cancel", true)
      else if (s.pc == "tools" and s.sub == "post") pairFrom(s, s.idx + 1, "cancel", false)
      else if (s.pc == "tools" and s.sub == "batch")
        pairFrom(batchResults(s), s.batchEnd, "cancel", false)
      else s
    s' = finish({ ...paired,
                  history: paired.history.append(mkAsst("aborted", [])),
                  cancels: s.cancels + 1 }, "cancelled", "cancel"),
  }

  // Dispatch on the appended assistant after the post-llm-end yield.
  action afterLlm = all {
    s.pc == "post",
    val a = lastMsg(s)
    if (a.stop == "error")
      s' = finish({ ...s, stepErr: true }, "error", "providerError")
    else if (toolTurn(a))
      if (s.toolNone)
        val r = pairFrom(s, 0, "refuse", false)
        if (s.refused + 1 > 1)
          s' = finish({ ...r, refused: s.refused + 1, consecRefused: s.consecRefused + 1,
                        stepErr: true }, "error", "refusedTwice")
        else
          s' = { ...r, refused: s.refused + 1, consecRefused: s.consecRefused + 1,
                 pc: "top", lastAction: "refused" }
      else if (s.badArgs)
        // same-turn-edit-conflicts indexes a number -> Lua error -> re-raised.
        // FIXED: the crash still happens, but the step boundary closes the
        // turn on any unwind, not just CANCEL-MARKER.
        s' = finish(if (FIXED) closeOpen({ ...s, stepErr: true }, "fail")
                    else { ...s, stepErr: true }, "crash", "crash")
      else
        s' = { ...s, pc: "tools", sub: "start", idx: 0, lastAction: "runTools" }
    else
      // natural stop: inject-after-natural-stop!
      val st = drain(s, true)
      val fu = if (st.drained and (st.appended or not(FIXED))) st else drain(st.s, false)
      val cont = if (FIXED) st.appended or fu.appended else st.drained or fu.drained
      if (cont)
        s' = { ...fu.s, pc: "top", refused: 0, lastAction: "inject" }
      else
        s' = finish(fu.s, "ok", "naturalStop"),
  }

  action toolStart = all {
    s.pc == "tools", s.sub == "start",
    if (s.par[s.idx])
      val e = batchEndFrom(s.par, s.idx)
      s' = { ...s, sub: "batch", batchEnd: e, batchOut: Map(),
             tcEv: s.tcEv.concat(slice2(s.calls, s.idx, e)),
             noneExecuted: s.noneExecuted or s.toolNone, lastAction: "launchBatch" }
    else
      s' = { ...s, sub: "pre", tcEv: s.tcEv.append(s.calls[s.idx]),
             noneExecuted: s.noneExecuted or s.toolNone, lastAction: "toolCall" },
  }

  action toolExec(ok: bool): bool = all {
    s.pc == "tools", s.sub == "pre",
    s' = { ...s, sub: "post",
           history: s.history.append(mkResult(s.calls[s.idx], if (ok) "real" else "fail")),
           trEv: s.trEv.append(s.calls[s.idx]), lastAction: "toolResult" },
  }

  action toolNext = all {
    s.pc == "tools", s.sub == "post",
    if (s.idx + 1 >= s.calls.length())
      s' = { ...s, pc: "top", sub: "start", lastAction: "toolsDone" }
    else
      s' = { ...s, sub: "start", idx: s.idx + 1, lastAction: "toolNext" },
  }

  action childDone(k: int, ok: bool): bool = all {
    s.pc == "tools", s.sub == "batch", s.idx <= k, k < s.batchEnd,
    not(s.batchOut.keys().contains(k)),
    s' = { ...s, batchOut: s.batchOut.put(k, if (ok) "real" else "fail"), lastAction: "childDone" },
  }

  action batchDone = all {
    s.pc == "tools", s.sub == "batch",
    s.batchOut.keys().size() == s.batchEnd - s.idx,
    val r = batchResults(s)
    if (s.batchEnd >= s.calls.length())
      s' = { ...r, pc: "top", sub: "start", idx: s.batchEnd, lastAction: "batchDone" }
    else
      s' = { ...r, sub: "start", idx: s.batchEnd, lastAction: "batchDone" },
  }

  action step = any {
    nondet none = Bool.oneOf()
    startStep(none),
    nondet steer = Bool.oneOf()
    nondet empty = Bool.oneOf()
    enqueue(steer, empty),
    loopTop,
    nondet o = OUTCOMES.oneOf()
    nondet p0 = Bool.oneOf()
    nondet p1 = Bool.oneOf()
    provider(o, p0, p1),
    cancel,
    afterLlm,
    toolStart,
    nondet ok = Bool.oneOf()
    toolExec(ok),
    toolNext,
    nondet k = 0.to(1).oneOf()
    nondet ok2 = Bool.oneOf()
    childDone(k, ok2),
    batchDone,
  }

  // ---- properties ----

  // Every provider request carries provider-valid tool-call/result pairing.
  val providerValidRequests = s.reqOk

  // Between steps the history is provider-valid (the next request sends it).
  val historyValidWhenIdle = s.pc == "idle" implies validCtx(s.history)

  // No provider request ends on an assistant message (an unrequested
  // continuation; Anthropic treats it as prefill).
  val requestsEndOnUserSide = s.reqNoTrailingAsst

  // Exactly one :aborted assistant per cancelled step, none otherwise.
  val abortedOncePerCancel =
    s.history.select(m => m.stop == "aborted").length() == s.cancels

  // Tool events mirror the appended results one-for-one, in order.
  val eventsMatchHistory =
    s.pc == "idle" implies (s.tcEv == s.trEv and s.trEv == resultIds(s.history))

  // :tool-choice :none never executes a tool, and ends the step on the
  // second refusal without intervening user input.
  val noneNeverExecutes = not(s.noneExecuted)
  val refusalCountsSinceInput = s.refused <= 2 and s.refused == s.consecRefused

  // Every queued line is pending, injected once, or dropped (only if empty).
  val queuedLinesDeliveredOnce =
    s.enqueued.foldl(true, (ok, l) =>
      val inQ = s.steerQ.foldl(0, (n, x) => if (x.id == l.id) n + 1 else n)
              + s.followQ.foldl(0, (n, x) => if (x.id == l.id) n + 1 else n)
      val inj = s.injected.foldl(0, (n, x) => if (x == l.id) n + 1 else n)
      val dr = s.dropped.foldl(0, (n, x) => if (x == l.id) n + 1 else n)
      ok and inQ + inj + dr == 1 and (dr == 1 implies l.empty))

  val boundedIterations = s.iters <= CAP

  // A step that ends in error says so on the bus.
  val errorSignalled = (s.pc == "idle" and s.result == "error") implies s.stepErr

  // :agent-turn-complete status agrees with what the step returned.
  val statusMatchesResult =
    (s.pc == "idle" and s.result != "none") implies
      s.status == (if (s.result == "crash") "error" else s.result)

  val allInvariants = and {
    providerValidRequests, historyValidWhenIdle, requestsEndOnUserSide,
    abortedOncePerCancel, eventsMatchHistory, noneNeverExecutes,
    refusalCountsSinceInput, queuedLinesDeliveredOnce, boundedIterations,
    errorSignalled, statusMatchesResult,
  }
}

// Every outcome a real provider can produce.
module current {
  import agentloop(FIXED = false,
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")).*
}
// Only well-formed replies: tool calls arrive with stop-reason :tool-use and
// parseable arguments. Isolates the cancel/refusal/queue machinery.
module wellFormed {
  import agentloop(FIXED = false, OUTCOMES = Set("text", "tool1", "tool2", "error")).*
}
// Isolate #606 (:length carrying a tool call).
module lengthOnly {
  import agentloop(FIXED = false, OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall")).*
}
// Isolate #607 (malformed edit arguments).
module badArgsOnly {
  import agentloop(FIXED = false, OUTCOMES = Set("text", "tool1", "tool2", "error", "badArgs")).*
}
module fixed {
  import agentloop(FIXED = true,
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")).*
}
