// Proof model: one subagent run's lifecycle, delivery, and budget (#646,
// #647, #648, #649). The integration model (../../model.qnt) has two runs,
// a follow-up queue, and inheritance; this one keeps only what these
// contracts need, all scalars, so Apalache can prove them inductively:
//
//   run       mode (blocking | background), status, process alive,
//             tool calls (capped), answered / steered / finalize-sent bits,
//             deliveries to the parent model, terminal transitions
//   delivery  whether the run's completion sits in the follow-up queue, and
//             whether it already sat there when the current prompt began
//   parent    idle | busy | gone
//
// One run is enough: every counterexample in the integration model uses one.
// Launch rejection (#645) and authority (#650) are the inheritance proof
// model's; here a launch always starts the child.
module lifecycle {
  // "646" quit reaps every run; "647" completions are drained at the top of
  // the turn; "648" wait consumes the completion and /cancel-all keeps it;
  // "649" a steer reopens the budget.
  const FIXES: Set[str]

  pure val MAX_TOOLS = 2
  pure val TOOL_CAP = 3

  pure def terminal(st: str): bool = st == "done" or st == "cancelled"
  pure def live(st: str): bool = st == "running" or st == "finalizing"

  var phase: str        // "idle" | "busy" | "gone"
  var mode: str         // "none" | "blocking" | "background"
  var st: str           // "none" | "running" | "finalizing" | "done" | "cancelled"
  var alive: bool
  var tools: int
  var finalSeen: bool   // run.final-answer-produced?
  var steered: bool
  var finSent: bool
  var told: int         // deliveries of the outcome to the parent model
  var terminals: int
  var queued: bool      // the completion is in the follow-up queue
  var pending: bool     // it was already queued when the prompt began
  // ghosts
  var staleAnswer: bool
  var budgetMissed: bool

  action init = all {
    phase' = "busy", mode' = "none", st' = "none", alive' = false, tools' = 0,
    finalSeen' = false, steered' = false, finSent' = false, told' = 0,
    terminals' = 0, queued' = false, pending' = false,
    staleAnswer' = false, budgetMissed' = false,
  }

  action keepRun = all {
    mode' = mode, st' = st, alive' = alive, tools' = tools, finalSeen' = finalSeen,
    steered' = steered, finSent' = finSent, told' = told, terminals' = terminals,
  }

  action keepGhosts = all { staleAnswer' = staleAnswer, budgetMissed' = budgetMissed }

  // ---- run ----
  action launch(m: str): bool = all {
    phase == "busy", mode == "none",
    mode' = m, st' = "running", alive' = true,
    tools' = tools, finalSeen' = finalSeen, steered' = steered, finSent' = finSent,
    told' = told, terminals' = terminals,
    phase' = phase, queued' = queued, pending' = pending, keepGhosts,
  }

  action childTool = all {
    alive, st == "running", tools < TOOL_CAP, not(finalSeen) or steered,
    tools' = tools + 1,
    mode' = mode, st' = st, alive' = alive, finalSeen' = finalSeen,
    steered' = steered, finSent' = finSent, told' = told, terminals' = terminals,
    phase' = phase, queued' = queued, pending' = pending, keepGhosts,
  }

  action childAnswer = all {
    alive, st == "running", not(finalSeen),
    finalSeen' = true, steered' = false,
    mode' = mode, st' = st, alive' = alive, tools' = tools, finSent' = finSent,
    told' = told, terminals' = terminals,
    phase' = phase, queued' = queued, pending' = pending, keepGhosts,
  }

  action steer = all {
    alive, st == "running", finalSeen, not(steered), phase != "gone",
    steered' = true, finalSeen' = not(FIXES.contains("649")),
    mode' = mode, st' = st, alive' = alive, tools' = tools, finSent' = finSent,
    told' = told, terminals' = terminals,
    phase' = phase, queued' = queued, pending' = pending, keepGhosts,
  }

  // pump! -> maybe-finalize!
  action pump = all {
    alive, st == "running", phase != "gone",
    val spent = tools >= MAX_TOOLS
    val sends = spent and not(finSent) and not(finalSeen)
    all {
      finSent' = (finSent or sends),
      st' = if (sends) "finalizing" else st,
      budgetMissed' = (budgetMissed or (spent and not(finSent) and finalSeen and steered)),
    },
    mode' = mode, alive' = alive, tools' = tools, finalSeen' = finalSeen,
    steered' = steered, told' = told, terminals' = terminals,
    phase' = phase, queued' = queued, pending' = pending, staleAnswer' = staleAnswer,
  }

  // finish!: blocking -> the tool result; background -> the follow-up queue.
  action exit = all {
    alive, live(st), phase != "gone",
    alive' = false, st' = "done", terminals' = terminals + 1,
    told' = if (mode == "blocking") told + 1 else told,
    queued' = if (mode == "background") true else queued,
    mode' = mode, tools' = tools, finalSeen' = finalSeen, steered' = steered,
    finSent' = finSent, phase' = phase, pending' = pending, keepGhosts,
  }

  // ---- parent ----
  // reap! of the run when it is alive and of mode `which`.
  action reap(which: str, ph: str, pend: bool): bool = all {
    val hit = alive and mode == which
    all {
      alive' = (alive and not(hit)),
      st' = if (hit) "cancelled" else st,
      terminals' = if (hit) terminals + 1 else terminals,
      told' = if (hit and which == "blocking") told + 1 else told,
      queued' = (queued or (hit and which == "background")),
    },
    mode' = mode, tools' = tools, finalSeen' = finalSeen, steered' = steered,
    finSent' = finSent, phase' = ph, pending' = pend, keepGhosts,
  }

  action userPrompt = all {
    phase == "idle", phase' = "busy", pending' = queued,
    keepRun, queued' = queued, keepGhosts,
  }

  // The model answers. Today the one queued completion is injected after
  // the answer (and the turn continues); fix 647 drains it first.
  action naturalStop = all {
    phase == "busy", not(alive and mode == "blocking"),
    val drainFirst = FIXES.contains("647") and queued
    val toldPre = if (drainFirst) told + 1 else told
    val q1 = queued and not(drainFirst)
    all {
      staleAnswer' = (staleAnswer or (pending and toldPre == 0)),
      told' = if (q1) toldPre + 1 else toldPre,
      queued' = false,
      phase' = if (q1) "busy" else "idle",
      pending' = false,
    },
    mode' = mode, st' = st, alive' = alive, tools' = tools, finalSeen' = finalSeen,
    steered' = steered, finSent' = finSent, terminals' = terminals,
    budgetMissed' = budgetMissed,
  }

  action wait = all {
    phase == "busy", mode == "background", terminal(st), told == 0,
    told' = 1, queued' = if (FIXES.contains("648")) false else queued,
    mode' = mode, st' = st, alive' = alive, tools' = tools, finalSeen' = finalSeen,
    steered' = steered, finSent' = finSent, terminals' = terminals,
    phase' = phase, pending' = pending, keepGhosts,
  }

  action parentCancel = all { phase == "busy", reap("blocking", "idle", false) }

  action cancelAll = all {
    phase == "idle", queued' = if (FIXES.contains("648")) queued else false,
    keepRun, phase' = phase, pending' = pending, keepGhosts,
  }

  action reload = all { phase == "idle", reap("background", phase, pending) }

  // quit: :agent-shutdown reaps background jobs; fix 646 reaps every run.
  action quit = all {
    phase != "gone",
    if (FIXES.contains("646")) reap(mode, "gone", pending)
    else reap("background", "gone", pending),
  }

  action step = any {
    nondet m = Set("blocking", "background").oneOf()
    launch(m),
    childTool, childAnswer, steer, pump, exit, wait,
    userPrompt, naturalStop, parentCancel, cancelAll, reload, quit,
  }

  // ---- properties (same names as the integration model) ----
  val terminalOnce = terminals <= 1
  val statusMatchesProcess = phase != "gone" implies live(st) == alive
  val toldAtMostOnce = told <= 1
  val toldOrPending = (phase != "gone" and terminal(st)) implies (told >= 1 or queued)
  val completionBeforeNextAnswer = not(staleAnswer)
  val budgetEnforced = not(budgetMissed)
  val noOrphanAfterQuit = phase == "gone" implies not(alive)

  val allInvariants = and {
    terminalOnce, statusMatchesProcess, toldAtMostOnce, toldOrPending,
    completionBeforeNextAnswer, budgetEnforced, noOrphanAfterQuit,
  }

  // ---- inductive strengthening (fixed) ----
  // Types and ranges first (Apalache's induction step starts anywhere), then
  // the facts the safety properties rest on.
  val typeOk = and {
    phase.in(Set("idle", "busy", "gone")),
    mode.in(Set("none", "blocking", "background")),
    st.in(Set("none", "running", "finalizing", "done", "cancelled")),
    alive.in(Set(true, false)), finalSeen.in(Set(true, false)),
    steered.in(Set(true, false)), finSent.in(Set(true, false)),
    queued.in(Set(true, false)), pending.in(Set(true, false)),
    staleAnswer.in(Set(true, false)), budgetMissed.in(Set(true, false)),
    tools.in(0.to(TOOL_CAP)), terminals.in(0.to(1)),
  }

  val strengthening = and {
    // a run exists iff it was launched; status, process, and terminals agree
    (mode == "none") == (st == "none"),
    alive == live(st),
    (terminals == 1) == terminal(st),
    // a live or unlaunched run has told nobody and queued nothing
    not(terminal(st)) implies (told == 0 and not(queued)),
    // a blocking outcome is the tool result (or the cancel pair), once
    (mode == "blocking" and terminal(st)) implies told == 1,
    (mode == "blocking") implies not(queued),
    // a queued completion is still undelivered
    queued implies told == 0,
    // a background outcome is delivered or still queued, even while gone
    (mode == "background" and terminal(st)) implies (told == 1 or queued),
    // a completion queued at the prompt is still queued, or was delivered
    pending implies (queued or told == 1),
    pending implies phase != "idle",
    // a steered run is not "answered"
    steered implies not(finalSeen),
  }

  val fixedInductive = and {
    told.in(0.to(1)), typeOk, strengthening,
    not(staleAnswer), not(budgetMissed), noOrphanAfterQuit,
  }

  // What holds today, inductively: one terminal status, a live status
  // exactly while the child exists (until quit), and at most two deliveries.
  val currentInductive = and {
    told.in(0.to(2)), typeOk,
    not(terminal(st)) implies (told == 0 and not(queued)),
    queued implies (told <= 1 and mode == "background"),
    (mode == "blocking" and terminal(st)) implies told == 1,
    (mode == "none") == (st == "none"),
    phase != "gone" implies alive == live(st),
    phase == "gone" implies (alive implies live(st)),
    (terminals == 1) == terminal(st),
  }
}

module current { import lifecycle(FIXES = Set()).* }
module fixed { import lifecycle(FIXES = Set("646", "647", "648", "649")).* }
module fix646 { import lifecycle(FIXES = Set("646")).* }
module fix647 { import lifecycle(FIXES = Set("647")).* }
module fix648 { import lifecycle(FIXES = Set("648")).* }
module fix649 { import lifecycle(FIXES = Set("649")).* }
