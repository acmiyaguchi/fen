// Model of fen's cooperative scheduler: the TUI presenter loop that drives
// every coroutine in the interactive process.
//
// One `iteration` action is one pass of `M.run` (tui/init.fnl):
//
//   1. paint      paint.advance-spinner-if-due! + paint.redraw-if-needed!
//                 (status items and panels are pcall'd per slot; transcript
//                 and input painting are not, and the call itself is not
//                 guarded by M.run)
//   2. peek       tb.peek_event (peek-timeout-ms is-busy?): 30 ms when dirty,
//                 Esc pending, main busy, side-chat busy, or a spinner is
//                 live; otherwise 300 ms. A key wakes the poll early.
//   3. input      input.handle-event under xpcall; the Ctrl-C ladder:
//                 busy & cancel-pressed? -> force quit; busy -> request
//                 cancel and arm cancel-pressed?; idle -> clear/arm quit.
//   4. on-tick    (interactive.fnl, under xpcall) emit :runtime-tick (each
//                 handler xpcall'd by the event bus: decide tasks, codex
//                 usage refresh, subagent job pumps, compaction), resume the
//                 main turn once, clear busy?/turn when it dies, emit
//                 :agent-turn-complete (goal may submit the next turn here),
//                 then, if idle, drain one reload request (starts a /reload
//                 turn) and start one idle follow-up.
//   5. background tick-background!: guard-tick! side-chat.tick! (one resume
//                 per live side turn, owner check, reap list) and
//                 workspaces.sync-subagents!; skipped when nested.
//   6. bottom     clear cancel-pressed? when it is set and (is-busy?) is false.
//
// Between iterations the environment may: emit a bus event whose transcript
// row cannot be rendered, queue a reload request from inside the agent turn
// (the `reload` tool), start a decide ask (ask-async!), open/submit the side
// chat. A /reload turn completing bumps the module generation; side turns
// owned by the previous generation are cancelled and reaped.
//
// Coroutine outcomes on resume: yield, finish, error. Agent turns observe a
// cancel at the first resume after the request (make-yield checks after
// coroutine.yield returns); /reload turns use plain coroutine.yield and never
// observe it (by design: reload is atomic).
//
// FIXES names the candidate fixes enabled (issue numbers, see FINDINGS.md).
module scheduler {
  const FIXES: Set[str]

  pure val ACTIVE_MS = 30
  pure val IDLE_MS = 300
  pure val MAX_TURNS = 4
  pure val MAX_BG = 2

  type S = {
    // loop
    loop: str,            // "running" | "crashed" | "exited"
    termRaw: bool,        // termbox owns the terminal (raw mode, mouse, paste)
    badRow: bool,         // transcript holds a row whose renderer raises
    // main turn (interactive run-state)
    mainKind: str,        // "none" | "agent" | "reload"
    busy: bool,           // state.busy?
    mainGen: int,         // state.turn-id (ghost identity of the coroutine)
    mainCancelReq: bool,  // state.cancel-requested?
    reloadQueued: bool,   // state.reload-requests non-empty
    // presenter Ctrl-C ladder
    cancelPressed: bool,  // tui state.cancel-pressed?
    pressGen: int,        // ghost: the turn the first Ctrl-C was aimed at
    quit: str,            // "" | "idle" | "forceOwn" | "forceFresh"
    // side chat
    sideAlive: bool, sideCancelReq: bool, sideOwner: int,
    moduleGen: int,       // bumped by a completed /reload
    staleLiveResume: bool, // ghost: a stale-owner side turn advanced as live
    // runtime-tick tasks (decide ask-async!, usage refresh-co, ...)
    bgTasks: int,
    lastBgGap: int,       // wall ms waited before the latest bg resume
    // per-pump counters: bumped by `age` at the start of every pump (an
    // iteration or a modal pump) and reset when that pump resumes the task.
    // Environment actions between pumps do not count, so these state
    // per-pump safety bounds, not eventual scheduling (no fairness is modelled).
    mainWait: int, sideWait: int, cancelAge: int,
    resumedDead: bool,
  }

  var s: S
  var lastAction: str

  action init = all {
    s' = {
      loop: "running", termRaw: true, badRow: false,
      mainKind: "none", busy: false, mainGen: 0, mainCancelReq: false,
      reloadQueued: false,
      cancelPressed: false, pressGen: 0, quit: "",
      sideAlive: false, sideCancelReq: false, sideOwner: 0, moduleGen: 0,
      staleLiveResume: false,
      bgTasks: 0, lastBgGap: 0,
      mainWait: 0, sideWait: 0, cancelAge: 0,
      resumedDead: false,
    },
    lastAction' = "init",
  }

  // ---- pure step functions, one per loop phase ----

  // 1. paint. A renderer error escapes M.run; interactive.fnl's xpcall then
  // runs presenter shutdown (terminal restored) and os.exit(1).
  pure def paint(st: S): S =
    if (st.badRow and not(FIXES.contains("635")))
      st.with("loop", "crashed").with("termRaw", false)
    else
      // fixed: per-row isolation renders a placeholder and the frame continues
      st.with("badRow", false)

  // 2. peek timeout predicate (peek-timeout-ms)
  pure def loopBusy(st: S): bool =
    st.busy or st.sideAlive or (FIXES.contains("637") and st.bgTasks > 0)

  pure def waitMs(st: S, key: bool): int =
    if (key) 0 else if (loopBusy(st)) ACTIVE_MS else IDLE_MS

  // 3. input: Ctrl-C ladder on the main tab (input.fnl handle-key)
  pure def ctrlC(st: S): S =
    if (st.busy and st.cancelPressed)
      st.with("quit", if (st.pressGen == st.mainGen) "forceOwn" else "forceFresh")
        .with("loop", "exited").with("termRaw", false)
    else if (st.busy)
      st.with("mainCancelReq", true).with("cancelPressed", true)
        .with("pressGen", st.mainGen)
    else st // idle: clear draft / arm second-press quit; not modelled further

  pure def submit(st: S): S =
    if (not(st.busy) and st.mainGen < MAX_TURNS)
      st.with("mainKind", "agent").with("busy", true)
        .with("mainGen", st.mainGen + 1).with("mainCancelReq", false)
    else st

  pure def input(st: S, ev: str): S =
    if (st.loop != "running") st
    else if (ev == "ctrlC") ctrlC(st)
    else if (ev == "submit") submit(st)
    else st

  // 4. on-tick: resume main once, finalize on death, then the idle boundary
  // fixed: finalizing a turn also disarms the Ctrl-C ladder for it, so the
  // arm can never outlive its turn (whichever pump finalizes it).
  pure def endMain(st: S): S =
    st.with("mainKind", "none").with("busy", false).with("mainCancelReq", false)
      .with("moduleGen", if (st.mainKind == "reload") st.moduleGen + 1 else st.moduleGen)
      .with("cancelPressed", if (FIXES.contains("636")) false else st.cancelPressed)

  pure def resumeMain(st: S, outcome: str): S =
    // on-tick resumes only `state.turn`, which is nil once the coroutine died;
    // a busy? flag that outlived its coroutine would mean a dead resume.
    if (st.mainKind == "none")
      st.with("mainWait", 0).with("resumedDead", st.resumedDead or st.busy)
    else
      val dies = (st.mainKind == "agent" and st.mainCancelReq)
                 or outcome == "finish" or outcome == "error"
      val st1 = st.with("mainWait", 0)
      if (dies) endMain(st1) else st1

  // A new turn may start inside the same on-tick that ended the previous one:
  // the deferred reload request (any end), or a goal continuation (only after
  // an :ok end). First-party code never starts one after a cancelled end other
  // than the reload drain; third-party api.enqueue idle follow-ups could.
  pure def idleBoundary(st: S, nextTurn: bool, endedCancelled: bool): S =
    if (st.busy or st.mainGen >= MAX_TURNS) st
    else if (st.reloadQueued)
      st.with("mainKind", "reload").with("busy", true)
        .with("mainGen", st.mainGen + 1).with("mainCancelReq", false)
        .with("reloadQueued", false)
    else if (nextTurn and not(endedCancelled))
      st.with("mainKind", "agent").with("busy", true)
        .with("mainGen", st.mainGen + 1).with("mainCancelReq", false)
    else st

  pure def bgPump(st: S, wait: int, bgFinish: bool): S =
    if (st.bgTasks == 0) st
    else st.with("lastBgGap", wait)
           .with("bgTasks", if (bgFinish) st.bgTasks - 1 else st.bgTasks)

  pure def onTick(st: S, outcome: str, nextTurn: bool, wait: int, bgFinish: bool): S =
    if (st.loop != "running") st
    // runtime-tick handlers run first, then the main resume
    else
      val cancelledNow = st.mainKind == "agent" and st.mainCancelReq
      idleBoundary(resumeMain(bgPump(st, wait, bgFinish), outcome), nextTurn,
                   cancelledNow)

  // 5. tick-background!: side-chat.tick! (guard-tick! isolates errors)
  pure def sideTick(st: S, outcome: str): S =
    if (st.loop != "running" or not(st.sideAlive)) st
    else if (st.sideOwner != st.moduleGen)
      // tick-one!: old owner -> request cancel and park for reap; the reap
      // resumes it, and the agent raises CANCEL-MARKER at that resume.
      if (st.sideCancelReq)
        st.with("sideAlive", false).with("sideCancelReq", false).with("sideWait", 0)
      else st.with("sideCancelReq", true).with("sideWait", 0)
    else
      val dies = st.sideCancelReq or outcome == "finish" or outcome == "error"
      st.with("sideWait", 0)
        .with("staleLiveResume", st.staleLiveResume or st.sideOwner != st.moduleGen)
        .with("sideAlive", not(dies))
        .with("sideCancelReq", if (dies) false else st.sideCancelReq)

  // 6. bottom-of-loop cancel-pressed? reset
  pure def bottom(st: S): S =
    if (st.loop != "running") st
    else
      val clear =
        if (FIXES.contains("636")) st.cancelPressed and (not(st.busy) or st.pressGen != st.mainGen)
        else st.cancelPressed and not(st.busy)
      if (clear) st.with("cancelPressed", false) else st

  // ghost bookkeeping before the iteration runs
  pure def age(st: S): S =
    st.with("mainWait", if (st.busy) st.mainWait + 1 else 0)
      .with("sideWait", if (st.sideAlive) st.sideWait + 1 else 0)
      .with("cancelAge",
            if (st.mainKind == "agent" and st.mainCancelReq) st.cancelAge + 1 else 0)

  pure def settle(st: S): S =
    // counters only count while there is something runnable
    st.with("mainWait", if (st.busy) st.mainWait else 0)
      .with("sideWait", if (st.sideAlive) st.sideWait else 0)
      .with("cancelAge",
            if (st.mainKind == "agent" and st.mainCancelReq) st.cancelAge else 0)

  // One pass of M.run with the environment's choices made explicit (the
  // phase order is the code's: paint, peek, input, on-tick, background, bottom;
  // #636 depends on input and on-tick running before the bottom reset).
  action iterate(ev: str, outcome: str, sideOutcome: str, nextTurn: bool,
                 bgFinish: bool): bool =
    all {
      s.loop == "running",
      val s0 = age(s)
      val s1 = paint(s0)
      val w = if (s1.loop == "running") waitMs(s1, ev != "none") else 0
      val s2 = input(s1, ev)
      val s3 = onTick(s2, outcome, nextTurn, w, bgFinish)
      val s4 = sideTick(s3, sideOutcome)
      s' = settle(bottom(s4)),
      lastAction' = ev,
    }

  action iteration = {
    nondet ev = Set("none", "ctrlC", "submit").oneOf()
    nondet outcome = Set("yield", "finish", "error").oneOf()
    nondet sideOutcome = Set("yield", "finish", "error").oneOf()
    nondet nextTurn = Set(true, false).oneOf()
    nondet bgFinish = Set(true, false).oneOf()
    iterate(ev, outcome, sideOutcome, nextTurn, bgFinish)
  }

  // ---- environment, between iterations ----

  // Any extension's api.emit (or a core event with a non-string field) puts
  // a row in the transcript that ingest accepts and render cannot draw.
  action emitBadRow = all {
    s.loop == "running", not(s.badRow),
    s' = s.with("badRow", true), lastAction' = "emitBadRow",
  }

  // The agent's `reload` tool enqueues a deferred request mid-turn.
  action agentQueuesReload = all {
    s.loop == "running", s.mainKind == "agent", not(s.reloadQueued),
    s' = s.with("reloadQueued", true), lastAction' = "agentQueuesReload",
  }

  // decide ask-async! (or usage refresh-co) creates a runtime-tick task.
  action startBgTask = all {
    s.loop == "running", s.bgTasks < MAX_BG,
    s' = s.with("bgTasks", s.bgTasks + 1), lastAction' = "startBgTask",
  }

  action submitSide = all {
    s.loop == "running", not(s.sideAlive),
    s' = s.with("sideAlive", true).with("sideCancelReq", false)
          .with("sideOwner", s.moduleGen),
    lastAction' = "submitSide",
  }

  action cancelSide = all {
    s.loop == "running", s.sideAlive,
    s' = s.with("sideCancelReq", true), lastAction' = "cancelSide",
  }

  // select.fnl run-overlay: a modal opened from the input handler (main
  // stack, turn suspended) polls termbox every 30 ms and pumps state.on-tick
  // and tick-background! itself; M.run's bottom-of-loop reset does not run.
  action pumpModal(outcome: str, sideOutcome: str, nextTurn: bool,
                  bgFinish: bool): bool =
    all {
      s.loop == "running",
      s' = settle(sideTick(onTick(age(s), outcome, nextTurn, ACTIVE_MS, bgFinish),
                           sideOutcome)),
      lastAction' = "modalPump",
    }

  action modalPump = {
    nondet outcome = Set("yield", "finish", "error").oneOf()
    nondet sideOutcome = Set("yield", "finish", "error").oneOf()
    nondet nextTurn = Set(true, false).oneOf()
    nondet bgFinish = Set(true, false).oneOf()
    pumpModal(outcome, sideOutcome, nextTurn, bgFinish)
  }

  action step = any {
    iteration, modalPump, emitBadRow, agentQueuesReload, startBgTask, submitSide, cancelSide,
  }

  // ---- properties ----

  // No fault in a tick source (paint included) ends the loop (#416 lesson).
  val loopSurvivesFaults = s.loop != "crashed"

  // Whenever the loop has stopped, the terminal is back in cooked mode.
  val terminalRestoredWhenStopped = s.loop != "running" implies not(s.termRaw)

  // A Ctrl-C only force-quits when the first press was aimed at the same turn.
  val forceQuitOnlyOnArmedTurn = s.quit != "forceFresh"

  // The armed first press always refers to the turn that is running now.
  val cancelArmMatchesTurn =
    s.cancelPressed implies (s.busy and s.pressGen == s.mainGen)

  // Pending cooperative work is polled at the active cadence, never the idle one.
  val pendingWorkPolledActively = s.lastBgGap <= ACTIVE_MS

  // Per-pump bound (safety, not liveness): every pump that starts with a
  // runnable main or side turn resumes it before the pump ends. The counters
  // only advance inside pumps, so this says nothing about how often pumps
  // run; no fairness is assumed, so no "eventually resumed" claim is made.
  val runnableResumedEachPump = s.mainWait <= 1 and s.sideWait <= 1

  // Per-pump bound: an agent turn whose cancel was requested before or during
  // a pump's input phase has ended when that pump finishes.
  val cancelledTurnEndsInPump = s.cancelAge <= 1

  // busy? (peek timeout, busy row, Ctrl-C ladder) matches the live coroutine.
  val busyMatchesAlive = s.busy == (s.mainKind != "none")

  // A side turn from a previous module generation is never advanced as live.
  val noStaleSideAdvanced = not(s.staleLiveResume)

  val noDeadResume = not(s.resumedDead)

  val allInvariants = and {
    loopSurvivesFaults, terminalRestoredWhenStopped, forceQuitOnlyOnArmedTurn,
    cancelArmMatchesTurn, pendingWorkPolledActively, runnableResumedEachPump,
    cancelledTurnEndsInPump, busyMatchesAlive, noStaleSideAdvanced,
    noDeadResume,
  }
}

module current { import scheduler(FIXES = Set()).* }
module fixed { import scheduler(FIXES = Set("635", "636", "637")).* }
module fix635 { import scheduler(FIXES = Set("635")).* }
module fix636 { import scheduler(FIXES = Set("636")).* }
module fix637 { import scheduler(FIXES = Set("637")).* }
