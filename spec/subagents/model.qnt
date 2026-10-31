// Model of fen's subagent orchestration, seen from the parent, as it works
// today. The wire protocol (acks, seq, the child state table, result-once)
// is the wire domain's: here the channel is a black box that delivers child
// events and lets the parent's driver send steer / finalize / close / cancel.
//
//   launch (subagent tool, parent turn busy)
//     launch!         -> child-tool-policy, effective-routing, runs.start!,
//                        start-child! (argv from routing + policy flags)
//     blocking        -> run-agent pumps the run inside the tool call,
//                        yielding to the parent turn; the result is the
//                        tool result
//     background      -> launch-background + runs.attach-job!; pumped from
//                        :runtime-tick; finish! queues the completion with
//                        steering.queue! :follow-up (never starts a turn)
//   driver (pump! -> drive!)
//     steering        -> runs.take-steering! -> `steer`
//     budget          -> maybe-finalize!: max-tool-calls / max-turns /
//                        checkpoint reached AND (not final-answer-produced?)
//                        AND not yet requested -> one `finalize`
//     exit            -> finish!: one terminal status, temp files removed
//   parent
//     natural stop    -> agent.step-loop: model answers, THEN drains one
//                        follow-up (inject-after-natural-stop!) and continues
//     turn cancel     -> the blocking run's yield raises: reap!, rethrow
//     wait            -> action=wait returns a finished run's result
//     /cancel-all     -> steering.clear-queues! (both queues)
//     /reload         -> M.register: shutdown-background-jobs! (not quiet)
//     quit / Ctrl-D   -> presenter exits; :agent-shutdown reaps runs.jobs
//                        only (background); the turn coroutine is dropped
//
// Inheritance is modelled for the three inputs that matter: the parent's
// thinking (ctx.agent has only `thinking-status`, a label like "think:8192"),
// hosted web search (lives in ctx.agent.provider-options, never forwarded),
// and the background "read-only" promise (prompt text only).
//
// FIXES names the candidate fixes by issue number, so each invariant can be
// checked against today's code, one fix, or all of them: "645" (inherit the
// thinking level), "646" (quit reaps every run), "647" (drain completions at
// the top of a turn), "648" (wait consumes, /cancel-all keeps completions),
// "649" (a steer reopens the budget), "650" (derived child policy).
module subagents {
  const FIXES: Set[str]

  pure val RUNS = Set(1, 2)
  pure val MAX_TOOLS = 2        // max-tool-calls budget for every run
  pure val TOOL_CAP = 4         // bound the state space

  // mode: "none" | "blocking" | "background"
  // st:   "none" | "running" | "finalizing" | "done" | "failed"
  //       | "timedout" | "cancelled"
  type Run = {
    mode: str,
    st: str,
    alive: bool,        // the child process exists
    tools: int,         // tool-call events observed
    finalSeen: bool,    // run.final-answer-produced?
    steered: bool,      // a steer was injected after an answer
    finSent: bool,      // run.budget-finalization-requested?
    told: int,          // deliveries of the outcome to the parent model
    terminals: int,     // terminal transitions
    canEdit: bool,      // child has edit/write/bash authority
    web: bool,          // child has hosted web search
  }

  pure def terminal(st: str): bool =
    Set("done", "failed", "timedout", "cancelled").contains(st)

  pure def live(st: str): bool = st == "running" or st == "finalizing"

  pure val EMPTY: Run = {
    mode: "none", st: "none", alive: false, tools: 0, finalSeen: false,
    steered: false, finSent: false, told: 0, terminals: 0, canEdit: false,
    web: false,
  }

  // ---- state ----
  var phase: str                 // parent: "idle" | "busy" | "gone"
  var runs: int -> Run
  var queue: List[int]           // follow-up queue entries (run ids)
  var pendingAtPrompt: Set[int]  // completions queued when the prompt began
  // environment, fixed per behaviour
  var parentThinking: bool       // parent runs with a thinking level
  var parentWebOff: bool         // parent passed --web-search off
  var settingsWeb: bool          // settings.json defaultWebSearch is on
  // ghosts
  var staleAnswer: bool          // model answered a prompt without a
                                 // completion that was already queued
  var budgetMissed: bool         // a pump saw an exhausted budget on a
                                 // live run and sent no finalize
  var startupRejected: bool      // a child refused its inherited argv
  var lastAction: str

  pure def removeAll(q: List[int], r: int): List[int] = q.select(x => x != r)

  // initWith takes the environment as arguments so witnesses can pin it.
  action initWith(t: bool, w: bool, s: bool): bool = all {
    phase' = "busy",
    runs' = RUNS.mapBy(_ => EMPTY),
    queue' = [],
    pendingAtPrompt' = Set(),
    parentThinking' = t, parentWebOff' = w, settingsWeb' = s,
    staleAnswer' = false, budgetMissed' = false, startupRejected' = false,
    lastAction' = "init",
  }

  action init = {
    nondet t = Set(true, false).oneOf()
    nondet w = Set(true, false).oneOf()
    nondet s = Set(true, false).oneOf()
    initWith(t, w, s)
  }

  // Frame helpers --------------------------------------------------------
  action keepEnv = all {
    parentThinking' = parentThinking, parentWebOff' = parentWebOff,
    settingsWeb' = settingsWeb,
  }

  // ---- launch ----------------------------------------------------------
  // effective-routing: thinking = cfg.thinking or ctx.opts.thinking (never
  // set in production) or ctx.agent.thinking (no such field) or
  // ctx.agent.thinking-status ("think:8192" / "reason:high"). The child's
  // main rejects that with exit 2 before speaking the wire.
  action launch(r: int, mode: str): bool = all {
    phase == "busy",
    runs.get(r).st == "none",
    val rejected = parentThinking and not(FIXES.contains("645"))
    // child-argv never forwards --web-search; the child reads settings.json.
    val childWeb = if (FIXES.contains("650")) settingsWeb and not(parentWebOff) else settingsWeb
    // a background child is "read-only" only in its prompt text.
    val childEdit = mode == "blocking" or not(FIXES.contains("650"))
    if (rejected)
      all {
        // the child exits 2 at startup: finish! settles it as failed
        runs' = runs.set(r, { ...EMPTY, mode: mode, st: "failed",
                              terminals: 1, canEdit: childEdit, web: childWeb,
                              told: if (mode == "blocking") 1 else 0 }),
        queue' = if (mode == "background") queue.append(r) else queue,
        startupRejected' = true,
      }
    else
      all {
        runs' = runs.set(r, { ...EMPTY, mode: mode, st: "running",
                              alive: true, canEdit: childEdit, web: childWeb }),
        queue' = queue,
        startupRejected' = startupRejected,
      },
    phase' = phase, pendingAtPrompt' = pendingAtPrompt, keepEnv,
    staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    lastAction' = "launch",
  }

  // ---- child behaviour (black-box channel) -----------------------------
  // One tool call. After a final answer the child only keeps working if a
  // steer was injected at that natural stop (inject-after-natural-stop!).
  action childTool(r: int): bool = all {
    val x = runs.get(r)
    all {
      x.alive, x.st == "running", x.tools < TOOL_CAP,
      not(x.finalSeen) or x.steered,
      runs' = runs.set(r, { ...x, tools: x.tools + 1 }),
    },
    phase' = phase, queue' = queue, pendingAtPrompt' = pendingAtPrompt,
    keepEnv, staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "childTool",
  }

  // A natural stop with a final answer (assistant-text :final? true).
  action childAnswer(r: int): bool = all {
    val x = runs.get(r)
    all {
      x.alive, x.st == "running", not(x.finalSeen),
      // a new natural stop consumes any earlier steer
      runs' = runs.set(r, { ...x, finalSeen: true, steered: false }),
    },
    phase' = phase, queue' = queue, pendingAtPrompt' = pendingAtPrompt,
    keepEnv, staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "childAnswer",
  }

  // A steer (/subagents steer, action=steer, a subagent tab) reaches the
  // child at that natural stop and the child resumes work. Fix 649: a resumed
  // run is no longer "answered" for budget purposes.
  action steer(r: int): bool = all {
    val x = runs.get(r)
    all {
      x.alive, x.st == "running", x.finalSeen, not(x.steered),
      phase != "gone",
      runs' = runs.set(r, { ...x, steered: true,
                            finalSeen: if (FIXES.contains("649")) false else true }),
    },
    phase' = phase, queue' = queue, pendingAtPrompt' = pendingAtPrompt,
    keepEnv, staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "steer",
  }

  // ---- parent driver (pump! -> drive! -> maybe-finalize!) --------------
  // A blocking run is pumped by its own tool call, a background run by
  // :runtime-tick; both need a live parent.
  pure def budgetSpent(x: Run): bool = x.tools >= MAX_TOOLS
  pure def sendsFinalize(x: Run): bool =
    budgetSpent(x) and not(x.finSent) and not(x.finalSeen)
  // the child is still working (after an answer it can only be, if steered)
  // and the budget is spent, yet no finalize is or was sent
  pure def missesFinalize(x: Run): bool =
    budgetSpent(x) and not(x.finSent) and x.finalSeen and x.steered

  action pump(r: int): bool = all {
    runs.get(r).alive, runs.get(r).st == "running", phase != "gone",
    runs' = runs.set(r, if (sendsFinalize(runs.get(r)))
                          { ...runs.get(r), finSent: true, st: "finalizing" }
                        else runs.get(r)),
    budgetMissed' = (budgetMissed or missesFinalize(runs.get(r))),
    phase' = phase, queue' = queue, pendingAtPrompt' = pendingAtPrompt,
    keepEnv, staleAnswer' = staleAnswer,
    startupRejected' = startupRejected, lastAction' = "pump",
  }

  // The child exits (close -> result -> exit, a crash, or its deadline).
  // finish!: one terminal status; blocking -> the tool result; background
  // -> queue-background-completion!.
  action exit(r: int, status: str): bool = all {
    val x = runs.get(r)
    all {
      x.alive, live(x.st), phase != "gone",
      runs' = runs.set(r, { ...x, alive: false, st: status,
                            terminals: x.terminals + 1,
                            told: if (x.mode == "blocking") x.told + 1
                                  else x.told }),
      queue' = if (x.mode == "background") queue.append(r) else queue,
    },
    phase' = phase, pendingAtPrompt' = pendingAtPrompt, keepEnv,
    staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "exit",
  }

  // ---- parent ----------------------------------------------------------
  pure def reapAll(rs: int -> Run, which: str): int -> Run =
    rs.keys().mapBy(k =>
      val x = rs.get(k)
      if (x.alive and x.mode == which)
        { ...x, alive: false, st: "cancelled", terminals: x.terminals + 1,
                // a cancelled blocking call is answered by the cancel pair
                told: if (which == "blocking") x.told + 1 else x.told }
      else x)

  pure def queueReaped(rs: int -> Run, q: List[int]): List[int] =
    q.concat(rs.keys().filter(k => rs.get(k).alive
                                   and rs.get(k).mode == "background")
               .fold([], (acc, k) => acc.append(k)))

  pure def blockingLive(rs: int -> Run): bool =
    rs.keys().exists(k => rs.get(k).alive and rs.get(k).mode == "blocking")

  action userPrompt = all {
    phase == "idle",
    phase' = "busy",
    pendingAtPrompt' = queue.foldl(Set(), (acc, k) => acc.union(Set(k))),
    runs' = runs, queue' = queue, keepEnv, staleAnswer' = staleAnswer,
    budgetMissed' = budgetMissed, startupRejected' = startupRejected,
    lastAction' = "userPrompt",
  }

  // The parent model answers. Today follow-ups are drained only after the
  // answer, one per natural stop; fix 647 drains completions first.
  action naturalStop = all {
    phase == "busy", not(blockingLive(runs)),
    val pre = if (FIXES.contains("647"))
                queue.foldl(runs, (rs, k) =>
                  rs.set(k, { ...rs.get(k), told: rs.get(k).told + 1 }))
              else runs
    val q1 = if (FIXES.contains("647")) [] else queue
    val stale = pendingAtPrompt.exists(k => pre.get(k).told == 0)
    all {
      staleAnswer' = (staleAnswer or stale),
      if (q1.length() > 0)
        all {
          runs' = pre.set(q1[0], { ...pre.get(q1[0]),
                                   told: pre.get(q1[0]).told + 1 }),
          queue' = q1.slice(1, q1.length()),
          phase' = "busy",
          pendingAtPrompt' = Set(),
        }
      else
        all { runs' = pre, queue' = q1, phase' = "idle",
              pendingAtPrompt' = Set() },
    },
    keepEnv, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "naturalStop",
  }

  // action=wait (or show) on a finished background run returns its result.
  // Fix 648: the returned result consumes the queued completion.
  action wait(r: int): bool = all {
    val x = runs.get(r)
    all {
      phase == "busy", x.mode == "background", terminal(x.st), x.told == 0,
      runs' = runs.set(r, { ...x, told: 1 }),
      queue' = if (FIXES.contains("648")) removeAll(queue, r) else queue,
    },
    phase' = phase, pendingAtPrompt' = pendingAtPrompt, keepEnv,
    staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "wait",
  }

  // Ctrl-C on a busy main turn: a blocking run's yield raises -> reap!.
  action parentCancel = all {
    phase == "busy",
    phase' = "idle",
    runs' = reapAll(runs, "blocking"),
    queue' = queue, pendingAtPrompt' = Set(), keepEnv,
    staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "parentCancel",
  }

  // /cancel-all while idle: steering.clear-queues!. Fix 648 keeps subagent
  // completions out of the user's follow-up queue.
  action cancelAll = all {
    phase == "idle",
    queue' = if (FIXES.contains("648")) queue else [],
    phase' = phase, runs' = runs, pendingAtPrompt' = pendingAtPrompt,
    keepEnv, staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "cancelAll",
  }

  // /reload (idle only: reload requests wait for the turn coroutine):
  // shutdown-background-jobs! reaps detached children, not quietly.
  action reload = all {
    phase == "idle",
    runs' = reapAll(runs, "background"),
    queue' = queueReaped(runs, queue),
    phase' = phase, pendingAtPrompt' = pendingAtPrompt, keepEnv,
    staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "reload",
  }

  // Ctrl-D (one press, even while busy) or /quit: the presenter loop ends,
  // :agent-shutdown reaps runs.jobs. Blocking runs are not jobs and their
  // owning turn coroutine is never resumed. Fix 646 reaps every active run.
  action quit = all {
    phase != "gone",
    phase' = "gone",
    val bg = reapAll(runs, "background")
    runs' = if (FIXES.contains("646")) reapAll(bg, "blocking") else bg,
    queue' = queue, pendingAtPrompt' = pendingAtPrompt, keepEnv,
    staleAnswer' = staleAnswer, budgetMissed' = budgetMissed,
    startupRejected' = startupRejected, lastAction' = "quit",
  }

  // Run-level and parent-level choices get equal weight in simulation.
  action runStep = {
    nondet r = RUNS.oneOf()
    any {
      nondet m = Set("blocking", "background").oneOf()
      launch(r, m),
      childTool(r),
      childAnswer(r),
      steer(r),
      pump(r),
      nondet s = Set("done", "failed", "timedout").oneOf()
      exit(r, s),
      wait(r),
    }
  }

  action parentStep = any {
    userPrompt,
    naturalStop,
    parentCancel,
    cancelAll,
    reload,
    quit,
  }

  action step = any { runStep, runStep, runStep, parentStep }

  // ---- properties -------------------------------------------------------

  // Every run reaches at most one terminal status.
  val terminalOnce = RUNS.forall(r => runs.get(r).terminals <= 1)

  // While the parent lives, a run is live exactly when its child process is.
  val statusMatchesProcess =
    phase != "gone" implies
      RUNS.forall(r => live(runs.get(r).st) == runs.get(r).alive)

  // The parent model is told each outcome at most once ...
  val toldAtMostOnce = RUNS.forall(r => runs.get(r).told <= 1)

  // ... and a finished run is either told or still pending delivery.
  val toldOrPending =
    phase != "gone" implies
      RUNS.forall(r => terminal(runs.get(r).st) implies
                         (runs.get(r).told >= 1 or queue.foldl(false, (f, k) => f or k == r)))

  // A completion queued before a user prompt reaches the model before it
  // answers that prompt.
  val completionBeforeNextAnswer = not(staleAnswer)

  // Every live run whose budget is spent gets a finalize.
  val budgetEnforced = not(budgetMissed)

  // No child process outlives the parent's normal quit.
  val noOrphanAfterQuit =
    phase == "gone" implies RUNS.forall(r => not(runs.get(r).alive))

  // A child accepts the routing it inherits from its parent.
  val inheritedRoutingAccepted = not(startupRejected)

  // Background jobs are read-only (docs/extensions.md, tool description).
  val backgroundReadOnly =
    RUNS.forall(r => (runs.get(r).mode == "background" and runs.get(r).alive)
                       implies not(runs.get(r).canEdit))

  // A child never has hosted web search its parent turned off.
  val noWiderNetwork =
    RUNS.forall(r => (runs.get(r).alive and parentWebOff)
                       implies not(runs.get(r).web))

  val allInvariants = and {
    terminalOnce, statusMatchesProcess, toldAtMostOnce, toldOrPending,
    completionBeforeNextAnswer, budgetEnforced, noOrphanAfterQuit,
    inheritedRoutingAccepted, backgroundReadOnly, noWiderNetwork,
  }
}

module current { import subagents(FIXES = Set("645", "646", "647", "648", "649", "650")).* }
module fixed { import subagents(FIXES = Set("645", "646", "647", "648", "649", "650")).* }
module fix645 { import subagents(FIXES = Set("645")).* }
module fix646 { import subagents(FIXES = Set("646")).* }
module fix647 { import subagents(FIXES = Set("647")).* }
module fix648 { import subagents(FIXES = Set("648")).* }
module fix649 { import subagents(FIXES = Set("649")).* }
module fix650 { import subagents(FIXES = Set("650")).* }
