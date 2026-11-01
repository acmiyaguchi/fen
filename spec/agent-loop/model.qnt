// Model of fen's agent step loop (agent.step / step-loop). With FIXES empty it
// is the loop as it was before the close-turn fix (#668); with every fix it is
// today's code (packages/core/src/fen/core/agent.fnl).
//
//   step            -> append UserMessage, run step-loop under xpcall; on
//                      CANCEL-MARKER append ONE empty :aborted assistant and
//                      emit :cancelled; any other error re-raises (the TUI's
//                      on-tick turns it into an "agent task:" :error event)
//                      ("607": close-turn! first pairs every call the newest
//                      assistant left open, on any unwind)
//   step-loop top   -> safety cap check (an ordinary :error exit, "610");
//                      drain steering (inject non-empty lines, reset
//                      refused-turns if any were injected); emit :llm-start;
//                      yield
//   provider        -> one nondeterministic outcome (network domain covers
//                      retries): text / tool-use with 1-2 calls / error /
//                      :length that still carries a tool call / tool-use
//                      whose edit arguments are malformed
//   after llm-end   -> append assistant; yield (before "607" a cancel paired
//                      calls only if stop-reason was :tool-use)
//   dispatch        -> :error -> :error event, stop
//                      tool calls ("606": any non-error reply carrying calls;
//                      before, only :tool-use) -> :none ? refuse (2nd refusal
//                      = error) : run-tool-calls
//                      anything else -> natural stop: poll steering, then
//                                       follow-up; continue only if a line
//                                       was appended ("608"; before, if the
//                                       drained list was non-empty)
//   run-tool-calls  -> same-turn-edit-conflicts over raw arguments, then
//                      serial calls (emit :tool-call, yield, execute, append,
//                      yield) and consecutive parallel-safe batches (launch
//                      all, children yield, results appended in order at the
//                      end); before "607" a cancel at any yield paired every
//                      unreturned call, now it only unwinds to the boundary
//
// The code no longer crashes on malformed edit arguments (edit-call-paths is
// type-tolerant); the "badArgs" outcome stays as the model's stand-in for any
// crash after the assistant is appended (e.g. a raising tool-context).
//
// Queues mirror extensions/behaviors/kernel/steering/service.fnl: steering
// and follow-up lines are appended while the agent is busy and drained
// one-at-a-time; a line may be "" (`>` alone strips to "").
//
// The lifecycle status mirrors packages/fen/src/fen/turn_lifecycle.fnl: it
// reads the step's own Outcome ("609"); before, it inferred status from the
// last message.
//
// FIXES names the fixes (by issue) so the same invariants can be checked with
// and without each.
module agentloop {
  // The pairing rule and the step outcome come from the close-turn core (#668).
  import turn.* from "../core/turn/turn"
  // The abstract spec the loop must refine (see module `refinement` below).
  import turnAbstract as TA from "../core/turn/abstract"

  const FIXES: Set[str]
  pure def fix(issue: str): bool = FIXES.contains(issue)
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
    hadToolNone: bool,       // ghost: any step had :tool-choice :none
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

  // Fix #607: the step boundary pairs whatever the last assistant left open,
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
  pure def batchResults(s: S, kind: str): S =
    val ks = range(s.idx, s.batchEnd)
    { ...s,
      history: ks.foldl(s.history, (h, k) =>
        h.append(mkResult(s.calls[k],
          if (s.batchOut.keys().contains(k)) s.batchOut.get(k) else kind))),
      trEv: ks.foldl(s.trEv, (t, k) => t.append(s.calls[k])) }

  // turn_lifecycle.complete-event (current) vs step result (fixed).
  pure def lifecycle(s: S, res: str): str =
    if (fix("609")) outcomeOf(res)
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
    m.stop == "tool" or (fix("606") and m.calls.length() > 0 and m.stop != "error")

  // first index >= i whose call is not parallel-safe
  pure def batchEndFrom(par: List[bool], i: int): int =
    range(i, par.length()).foldl({ end: par.length(), open: true }, (acc, k) =>
      if (acc.open and not(par[k])) { end: k, open: false } else acc).end

  // Refinement mapping onto the abstract close-turn spec. Open calls come
  // from what is actually in the history (core `openCalls`); in-flight
  // history is never closed first, so a missing close shows up as an
  // abstract step that does not exist.
  pure def absOf(st: S): TA::Abs =
    val op = openCalls(entries(st.history))
    {
      open: op,
      turnOpen: st.pc != "idle",
      awaiting: op == NOCALLS and st.history.length() > 0 and lastCtxRole(st.history) != "asst",
      outcome: if (st.pc == "idle" and st.result != "none") st.status else "none",
      errSignalled: st.stepErr,
      replies: ctx(st.history).select(m => m.role == "asst").length() % 2 == 1,
    }

  // ---- state ----
  var s: S

  action init = s' = {
    pc: "idle", sub: "start", history: [], calls: [], par: [], idx: 0, batchEnd: 0,
    batchOut: Map(), badArgs: false, toolNone: false, hadToolNone: false, refused: 0, consecRefused: 0,
    iters: 0, steps: 0, nextCall: 0, nextLine: 0, steerQ: [], followQ: [],
    enqueued: [], injected: [], dropped: [], tcEv: [], trEv: [], stepErr: false,
    result: "none", status: "none", reqOk: true, reqNoTrailingAsst: true,
    noneExecuted: false, cancels: 0, lastAction: "init",
  }

  // ---- environment: the user ----
  action startStep(none: bool): bool = all {
    s.pc == "idle", s.steps < MAX_STEPS,
    s' = { ...appendUser(s, "prompt"),
           pc: "top", steps: s.steps + 1, toolNone: none, hadToolNone: s.hadToolNone or none,
           refused: 0, iters: 0,
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
      s' = finish({ ...s, stepErr: s.stepErr or fix("610") }, "error", "safetyCap")
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
      // Fix #607: the batch runner still appends finished children in call
      // order; everything else is the boundary's job.
      if (fix("607"))
        closeOpen(if (s.pc == "tools" and s.sub == "batch") batchResults(s, "cancel") else s, "cancel")
      else if (s.pc == "post")
        if (toolTurn(lastMsg(s))) pairFrom(s, 0, "cancel", false) else s
      else if (s.pc == "tools" and s.sub == "pre") pairFrom(s, s.idx, "cancel", true)
      else if (s.pc == "tools" and s.sub == "post") pairFrom(s, s.idx + 1, "cancel", false)
      else if (s.pc == "tools" and s.sub == "batch")
        pairFrom(batchResults(s, "cancel"), s.batchEnd, "cancel", false)
      else s
    s' = finish({ ...paired,
                  history: paired.history.append(mkAsst("aborted", [])),
                  cancels: s.cancels + 1 }, "cancelled", "cancel"),
  }

  // A non-cancel error from ?yield! mid-tools (e.g. mid-batch after some
  // child finished): finished batch children keep their results, and the
  // rest of the batch + open calls are paired as "fail" ("interrupted"),
  // never "cancel".
  action toolCrash = all {
    OUTCOMES.contains("badArgs"),
    s.pc == "tools",
    s.sub == "pre" or s.sub == "post"
      or (s.sub == "batch" and s.batchOut.keys().size() < s.batchEnd - s.idx),
    val paired =
      if (fix("607"))
        closeOpen(if (s.sub == "batch") batchResults(s, "fail") else s, "fail")
      else s
    s' = finish({ ...paired, stepErr: true }, "crash", "crash"),
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
        // Fix #607: the crash still happens, but the step boundary closes the
        // turn on any unwind, not just CANCEL-MARKER.
        s' = finish(if (fix("607")) closeOpen({ ...s, stepErr: true }, "fail")
                    else { ...s, stepErr: true }, "crash", "crash")
      else
        s' = { ...s, pc: "tools", sub: "start", idx: 0, lastAction: "runTools" }
    else
      // natural stop: inject-after-natural-stop!
      val st = drain(s, true)
      val fu = if (st.drained and (st.appended or not(fix("608")))) st else drain(st.s, false)
      val cont = if (fix("608")) st.appended or fu.appended else st.drained or fu.drained
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
    val r = batchResults(s, "fail")
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
    toolCrash,
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

  // Result kinds match the transition that produced them: "cancel" results
  // only appear when a step was cancelled, and "refuse" only under :none.
  val resultKindsMatchOutcome =
    s.history.foldl(true, (ok, m) =>
      ok and (m.role == "result" implies
        ((m.kind == "cancel" implies s.cancels > 0)
         and (m.kind == "refuse" implies s.hadToolNone))))

  val allInvariants = and {
    providerValidRequests, historyValidWhenIdle, requestsEndOnUserSide,
    abortedOncePerCancel, eventsMatchHistory, noneNeverExecutes,
    refusalCountsSinceInput, queuedLinesDeliveredOnce, boundedIterations,
    errorSignalled, statusMatchesResult, resultKindsMatchOutcome,
  }
}

// Today's loop, over every outcome a real provider can produce. The code
// carries #606-#610 (the close-turn boundary, #668), so current == fixed;
// the fix<issue> instances and mutants.tsv keep each bug reachable.
module current {
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"),
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")).*
}
// Only well-formed replies: tool calls arrive with stop-reason :tool-use and
// parseable arguments. Isolates the cancel/refusal/queue machinery.
module wellFormed {
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"), OUTCOMES = Set("text", "tool1", "tool2", "error")).*
}
// Isolate #606 (:length carrying a tool call).
module lengthOnly {
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"), OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall")).*
}
// Isolate #607 (malformed edit arguments).
module badArgsOnly {
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"), OUTCOMES = Set("text", "tool1", "tool2", "error", "badArgs")).*
}
module fixed {
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"),
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")).*
}

// One fix at a time, each over the provider outcomes that isolate its bug.
module fix606 { import agentloop(FIXES = Set("606"), OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall")).* }
module fix607 { import agentloop(FIXES = Set("607"), OUTCOMES = Set("text", "tool1", "tool2", "error", "badArgs")).* }
module fix608 { import agentloop(FIXES = Set("608"), OUTCOMES = Set("text", "tool1", "tool2", "error")).* }
module fix609 { import agentloop(FIXES = Set("609"), OUTCOMES = Set("text", "tool1", "tool2", "error")).* }
module fix610 { import agentloop(FIXES = Set("610"), OUTCOMES = Set("text", "tool1", "tool2", "error")).* }

// Refinement monitor: every step of the loop must be a step (or stutter) of
// the abstract close-turn spec (spec/core/turn/abstract.qnt), checked on the
// concrete transition itself through a ghost copy of the previous abstract
// state. The abstract invariants (proved inductively in spec/core/turn) then
// hold for the loop too. The two monitors are spelled out rather than one
// parameterised module: quint test mixes up two instances of one module that
// share an inner alias.
module currentRefines {
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"),
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")) as LC
  import turnAbstract as TA from "../core/turn/abstract"

  var prevAbs: TA::Abs

  action init = all { LC::init, prevAbs' = TA::absInit }
  action step = all { LC::step, prevAbs' = LC::absOf(LC::s) }

  // Deterministic wrappers for witnesses.
  action mStartStep(none: bool): bool = all { LC::startStep(none), prevAbs' = LC::absOf(LC::s) }
  action mEnqueue(steer: bool, empty: bool): bool = all { LC::enqueue(steer, empty), prevAbs' = LC::absOf(LC::s) }
  action mLoopTop = all { LC::loopTop, prevAbs' = LC::absOf(LC::s) }
  action mProvider(o: str): bool = all { LC::provider(o, false, false), prevAbs' = LC::absOf(LC::s) }
  action mAfterLlm = all { LC::afterLlm, prevAbs' = LC::absOf(LC::s) }
  action mToolStart = all { LC::toolStart, prevAbs' = LC::absOf(LC::s) }
  action mToolExec = all { LC::toolExec(true), prevAbs' = LC::absOf(LC::s) }
  action mToolNext = all { LC::toolNext, prevAbs' = LC::absOf(LC::s) }
  action mCancel = all { LC::cancel, prevAbs' = LC::absOf(LC::s) }
  action mToolCrash = all { LC::toolCrash, prevAbs' = LC::absOf(LC::s) }

  // What the step returned (for witnesses).
  val stepResult = LC::s.result

  // The last step was an abstract step or a stutter.
  val refinesTurn = TA::absNext(prevAbs, LC::absOf(LC::s))
  // The abstract invariants, read through the mapping.
  val inheritsTurnInvariants = TA::absInv(LC::absOf(LC::s))
}

module fixedRefines {
  import agentloop(FIXES = Set("606", "607", "608", "609", "610"),
    OUTCOMES = Set("text", "tool1", "tool2", "error", "lengthCall", "badArgs")) as LF
  import turnAbstract as TA from "../core/turn/abstract"

  var prevAbs: TA::Abs

  action init = all { LF::init, prevAbs' = TA::absInit }
  action step = all { LF::step, prevAbs' = LF::absOf(LF::s) }

  // Deterministic wrappers for witnesses.
  action mStartStep(none: bool): bool = all { LF::startStep(none), prevAbs' = LF::absOf(LF::s) }
  action mEnqueue(steer: bool, empty: bool): bool = all { LF::enqueue(steer, empty), prevAbs' = LF::absOf(LF::s) }
  action mLoopTop = all { LF::loopTop, prevAbs' = LF::absOf(LF::s) }
  action mProvider(o: str): bool = all { LF::provider(o, false, false), prevAbs' = LF::absOf(LF::s) }
  action mAfterLlm = all { LF::afterLlm, prevAbs' = LF::absOf(LF::s) }
  action mToolStart = all { LF::toolStart, prevAbs' = LF::absOf(LF::s) }
  action mToolExec = all { LF::toolExec(true), prevAbs' = LF::absOf(LF::s) }
  action mToolNext = all { LF::toolNext, prevAbs' = LF::absOf(LF::s) }
  action mCancel = all { LF::cancel, prevAbs' = LF::absOf(LF::s) }
  action mToolCrash = all { LF::toolCrash, prevAbs' = LF::absOf(LF::s) }

  // What the step returned (for witnesses).
  val stepResult = LF::s.result

  // The last step was an abstract step or a stutter.
  val refinesTurn = TA::absNext(prevAbs, LF::absOf(LF::s))
  // The abstract invariants, read through the mapping.
  val inheritsTurnInvariants = TA::absInv(LF::absOf(LF::s))
}
