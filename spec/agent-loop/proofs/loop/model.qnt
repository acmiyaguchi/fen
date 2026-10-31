// Proof model of the agent step loop's control decisions, with no transcript:
// the latest reply's calls and how many are answered, whether the model is
// owed a reply, the refusal and iteration counters, one follow-up slot, and
// the step's result and reported status. Every step is checked against the
// abstract close-turn spec (spec/core/turn/abstract.qnt) through a ghost copy
// of the previous abstract state, so Apalache can prove refinement for the
// loop (verify.tsv). Before the close-turn fix (#668) the loop failed it in
// five ways, #606-#610; the mutants in mutants.tsv bring those failures back.
//
// Mirrors agent.fnl step / step-loop / run-tool-calls like the integration
// model (spec/agent-loop/model.qnt), but folds serial and parallel tool runs
// into "the next call is answered" and steering into the follow-up slot.
//
// Input assumptions: one user step per run (MAX_STEPS = 1); the provider
// returns text, one or two tool calls, an error, a :length reply carrying
// one call, or one call with malformed edit arguments; at most one queued
// follow-up line, empty or not; CAP = 2 iterations.
module loopProof {
  import turnAbstract.* from "../../../core/turn/abstract"

  const FIXES: Set[str]
  pure def fix(issue: str): bool = FIXES.contains(issue)

  pure val CAP = 2
  pure val NOCALLS: List[int] = []

  type L = {
    pc: str,          // "idle" | "top" | "llm" | "post" | "tools"
    calls: List[int], // calls of the latest reply that is in context
    answered: int,    // how many of them have a result
    stop: str,        // latest reply's stop label: "stop" | "tool" | "length" | "error"
    badArgs: bool,    // latest reply's edit arguments are malformed
    awaiting: bool,   // the model is owed a reply
    parity: bool,     // parity of in-context replies
    toolNone: bool,   // :tool-choice :none
    refused: int,
    iters: int,
    slot: str,        // queued follow-up: "none" | "empty" | "line"
    stepErr: bool,    // an :error event was emitted in this step
    lastErrReply: bool, // the last message is an :error assistant (turn_lifecycle reads it)
    result: str,      // "none" | "ok" | "error" | "cancelled" | "crash"
    status: str,      // :agent-turn-complete status
    steps: int,
  }

  pure val L0: L = {
    pc: "idle", calls: NOCALLS, answered: 0, stop: "stop", badArgs: false,
    awaiting: false, parity: false, toolNone: false, refused: 0, iters: 0,
    slot: "none", stepErr: false, lastErrReply: false, result: "none",
    status: "none", steps: 0,
  }

  pure def openOf(l: L): List[int] = l.calls.slice(l.answered, l.calls.length())

  pure def absOf(l: L): Abs = {
    open: openOf(l),
    turnOpen: l.pc != "idle",
    awaiting: l.awaiting and openOf(l) == NOCALLS,
    outcome: if (l.pc == "idle" and l.result != "none") l.status else "none",
    errSignalled: l.stepErr,
    replies: l.parity,
  }

  // turn_lifecycle.complete-event today (infers from the last message) vs the
  // step's own outcome (#609).
  pure def statusOf(l: L, res: str): str =
    if (fix("609")) (if (res == "crash") "error" else res)
    else if (res == "crash") "error"
    else if (res == "cancelled") "cancelled"
    else if (l.lastErrReply) "error"
    else "ok"

  pure def finish(l: L, res: str): L =
    { ...l, pc: "idle", result: res, status: statusOf(l, res) }

  // Pair every open call with a synthetic result.
  pure def pairAll(l: L): L =
    if (openOf(l) == NOCALLS) l else { ...l, answered: l.calls.length(), awaiting: true }

  // A reply with calls takes the tool path: today only when the stop label
  // says so (#606), with the fix whenever it carries calls.
  pure def toolTurn(l: L): bool =
    l.stop == "tool" or (fix("606") and l.calls != NOCALLS and l.stop != "error")

  var l: L
  var prevAbs: Abs

  action go(n: L): bool = all { l' = n, prevAbs' = absOf(l) }

  action init = all { l' = L0, prevAbs' = absInit }

  action startStep(none: bool): bool = all {
    l.pc == "idle", l.steps < 1,
    go({ ...L0, pc: "top", awaiting: true, parity: l.parity, toolNone: none, steps: l.steps + 1 }),
  }

  action enqueue(line: str): bool = all {
    l.pc != "idle", l.slot == "none",
    go({ ...l, slot: line }),
  }

  action loopTop = all {
    l.pc == "top",
    if (l.iters >= CAP)
      go(finish({ ...l, stepErr: l.stepErr or fix("610") }, "error"))
    else
      go({ ...l, pc: "llm", iters: l.iters + 1 }),
  }

  action provider(o: str): bool = all {
    l.pc == "llm",
    if (o == "error")
      // an :error assistant is recorded but kept out of context
      go({ ...l, pc: "post", stop: "error", lastErrReply: true })
    else
      val cs = if (o == "tool2") [0, 1] else if (o == "text") NOCALLS else [0]
      go({ ...l, pc: "post", calls: cs, answered: 0, badArgs: o == "badArgs",
            stop: if (o == "text") "stop" else if (o == "length") "length" else "tool",
            awaiting: false, parity: not(l.parity), lastErrReply: false }),
  }

  action afterLlm = all {
    l.pc == "post",
    if (l.stop == "error")
      go(finish({ ...l, stepErr: true }, "error"))
    else if (toolTurn(l))
      if (l.toolNone)
        val r = { ...pairAll(l), refused: l.refused + 1 }
        if (l.refused + 1 > 1) go(finish({ ...r, stepErr: true }, "error"))
        else go({ ...r, pc: "top" })
      else if (l.badArgs)
        // same-turn-edit-conflicts raises; with #607 the step boundary
        // closes the turn on any unwind
        go(finish(if (fix("607")) pairAll({ ...l, stepErr: true }) else { ...l, stepErr: true }, "crash"))
      else go({ ...l, pc: "tools" })
    else
      // natural stop: drain the follow-up slot
      if (l.slot == "line")
        go({ ...l, slot: "none", pc: "top", awaiting: true, refused: 0 })
      else if (l.slot == "empty" and not(fix("608")))
        // nothing appended, but the loop continues anyway
        go({ ...l, slot: "none", pc: "top", refused: 0 })
      else
        go(finish({ ...l, slot: "none" }, "ok")),
  }

  action toolRun = all {
    l.pc == "tools", openOf(l) != NOCALLS,
    val n = { ...l, answered: l.answered + 1 }
    go(if (openOf(n) == NOCALLS) { ...n, pc: "top", awaiting: true } else n),
  }

  // CANCEL-MARKER at a yield. Today each exit pairs on its own; after
  // llm-end only when the stop label is :tool-use (#606). With #607 the step
  // boundary pairs whatever is open.
  action cancel = all {
    l.pc == "llm" or l.pc == "post" or l.pc == "tools",
    val paired =
      if (fix("607")) pairAll(l)
      else if (l.pc == "post") (if (l.stop == "tool") pairAll(l) else l)
      else pairAll(l)
    go(finish(paired, "cancelled")),
  }

  action step = any {
    nondet none = Bool.oneOf()
    startStep(none),
    nondet line = Set("empty", "line").oneOf()
    enqueue(line),
    loopTop,
    nondet o = Set("text", "tool1", "tool2", "error", "length", "badArgs").oneOf()
    provider(o),
    afterLlm,
    toolRun,
    cancel,
  }

  // ---- properties ----
  val refinesTurn = absNext(prevAbs, absOf(l))
  val inheritsTurnInvariants = absInv(absOf(l))
}

// Today's loop: #606-#610 are fixed in the code (the close-turn boundary, #668).
module current { import loopProof(FIXES = Set("606", "607", "608", "609", "610")).* }
module fixed { import loopProof(FIXES = Set("606", "607", "608", "609", "610")).* }
