// Model of who owns a turn, its keys, and its events in fen's TUI.
//
// Three tabs: "main" (the interactive session), "side" (the /btw singleton,
// kind :side-chat) and "sub" (one retained subagent run, kind :subagent-job).
// The presenter state is a single record `s`; each action is one key, mouse
// click, bus event, or tick, mirroring:
//
//   input.fnl        handle-key: Ctrl-C ladder, Enter submit, Ctrl-W close,
//                    Alt-arrow focus; handle-mouse: tab click (no key path)
//   workspaces.fnl   KINDS policy (capabilities, cancel!, close!), activate!
//                    view swap (save-view!/load-view!), append-to!, with-main!
//   side_chat.fnl    volatile.live entry keyed by WORKSPACE-ID, entry-for!,
//                    cancel! (8 bounded resumes, else park for reap),
//                    on-event! routed by id, finish-turn!
//   panels/busy.fnl  busy row + cancel-hint
//   init.fnl         run loop: tick-background!, cancel-pressed? reset
//   steering/service.fnl + core/agent.fnl  steering queue drained only at a
//                    natural stop or at the top of the next step-loop
//
// FIXES names the candidate fixes enabled, by issue (see FINDINGS.md):
//   "660" the main cancel/force-quit ladder applies only on the main tab
//   "661" workspaces.activate! disarms the pending quit (mouse path too)
//   "662" a turn that ends by error or cancel hands its steering back
//   "663" the slow cancel path moves the turn to the reap list, and side
//         events route to the tab generation that started the turn
module tuiTurns {
  const FIXES: Set[str]

  pure val MAX_MAIN_TURNS = 3
  pure val MAX_SIDE_GENS = 3
  pure val MAX_STEER = 3
  pure val TABS = Set("main", "side", "sub")

  // A transcript row remembers which tab's turn produced it (ghost data);
  // gen is the btw tab generation for side rows, 0 otherwise.
  type Row = { origin: str, gen: int }
  // A steering line remembers the main turn it was typed for.
  type Delivery = { typedFor: int, deliveredIn: int }
  // volatile.live[:btw] while a side turn coroutine exists.
  type Live = { present: bool, gen: int, cancel: bool, discard: bool }

  type S = {
    focus: str,
    // main session (run-state)
    mainBusy: bool, mainCancelReq: bool, mainTurn: int,
    cancelPressed: bool, pendingQuit: bool, armedOn: str, quit: bool,
    steerQ: List[int], delivered: List[Delivery], typedSteer: int, returned: int,
    // side chat
    sideOpen: bool, sideGen: int, sideBusy: bool, live: Live, reaping: List[int],
    // subagent run + its tab
    subStatus: str, subOpen: bool, subSteers: int,
    // per-tab view: `view` is state.* (the focused tab's draft); rec holds the rest
    view: int, rec: str -> int, intended: str -> int,
    transcripts: str -> List[Row],
  }

  var s: S
  var lastAction: str

  pure val NO_LIVE = { present: false, gen: 0, cancel: false, discard: false }

  action init = all {
    s' = {
      focus: "main",
      mainBusy: false, mainCancelReq: false, mainTurn: 0,
      cancelPressed: false, pendingQuit: false, armedOn: "", quit: false,
      steerQ: [], delivered: [], typedSteer: 0, returned: 0,
      sideOpen: false, sideGen: 0, sideBusy: false, live: NO_LIVE, reaping: [],
      subStatus: "none", subOpen: false, subSteers: 0,
      view: 0,
      rec: Map("main" -> 0, "side" -> 0, "sub" -> 0),
      intended: Map("main" -> 0, "side" -> 0, "sub" -> 0),
      transcripts: Map("main" -> [], "side" -> [], "sub" -> []),
    },
    lastAction' = "init",
  }

  // ---- derived views (pure functions of s) ----
  pure def isOpen(st: S, t: str): bool =
    if (t == "main") true else if (t == "side") st.sideOpen else st.subOpen

  pure def draftOf(st: S, t: str): int =
    if (t == st.focus) st.view else st.rec.get(t)

  pure def sideRunning(st: S): bool = st.sideOpen and st.sideBusy
  pure def subRunning(st: S): bool = st.subStatus == "running"

  // workspaces.capabilities-for
  pure def allowsSubmit(st: S, t: str): bool =
    if (t == "main") true else if (t == "side") not(sideRunning(st)) else false
  pure def acceptsInput(st: S, t: str): bool =
    if (t == "sub") subRunning(st) else true

  // input.handle-key, KEY_CTRL_C branch
  pure def ctrlCEffect(st: S): str =
    val ladder =
      if (allowsSubmit(st, st.focus) and draftOf(st, st.focus) != 0 and not(st.pendingQuit)) "clearDraft"
      else if (st.pendingQuit) "quit"
      else "arm"
    if (st.focus == "side" and sideRunning(st)) "cancelSide"   // workspaces.cancel-active!
    else if (FIXES.contains("660") and st.focus != "main") ladder               // fix: main ladder only on main
    else if (st.mainBusy and st.cancelPressed) "forceQuit"
    else if (st.mainBusy) "cancelMain"
    else ladder

  // panels/busy.fnl
  pure def busyRowVisible(st: S): bool =
    if (st.focus == "main") st.mainBusy
    else if (st.focus == "side") sideRunning(st)
    else st.subOpen and subRunning(st)

  pure def busyHint(st: S): str =
    if (st.focus == "main") (if (st.cancelPressed) "forceQuit" else "cancel")
    else if (st.focus == "side") "cancel"   // kind has cancel!
    else "none"                             // subagent kind: hint omitted

  pure def hintOf(e: str): str =
    if (e == "cancelMain" or e == "cancelSide") "cancel"
    else if (e == "forceQuit") "forceQuit"
    else "none"

  // workspaces.activate!: capture-active! then load-view!
  pure def switchTo(st: S, t: str): S =
    { ...st, rec: st.rec.put(st.focus, st.view), view: st.rec.get(t), focus: t }

  pure def setDraft(st: S, v: int): S =
    { ...st, view: v, intended: st.intended.put(st.focus, v) }

  pure def appendRow(st: S, t: str, r: Row): S =
    { ...st, transcripts: st.transcripts.put(t, st.transcripts.get(t).append(r)) }

  // Every key except Ctrl-C disarms the pending quit (top of handle-key).
  pure def key(st: S): S = { ...st, pendingQuit: false }

  action go(nx: S, name: str): bool = all { s' = nx, lastAction' = name }

  // ---- user: keys ----
  action typeKey = all {
    not(s.quit), acceptsInput(s, s.focus), s.view == 0,
    go(key(s).setDraft(1), "type"),
  }

  action focusKey(t: str): bool = all {
    not(s.quit), isOpen(s, t), t != s.focus,
    go(key(s).switchTo(t), "focusKey"),
  }

  // Tab click: handle-mouse calls activate! without the handle-key preamble.
  action focusMouse(t: str): bool = all {
    not(s.quit), isOpen(s, t), t != s.focus,
    val base = if (FIXES.contains("661")) key(s) else s   // fix: activate! disarms
    go(base.switchTo(t), "focusMouse"),
  }

  action ctrlC = all {
    not(s.quit),
    val e = ctrlCEffect(s)
    val nx =
      if (e == "cancelSide") { ...s, live: if (s.live.present) { ...s.live, cancel: true } else s.live }
      else if (e == "cancelMain") { ...s, mainCancelReq: true, cancelPressed: true }
      else if (e == "forceQuit" or e == "quit") { ...s, quit: true }
      else if (e == "clearDraft") s.setDraft(0)
      else { ...s, pendingQuit: true, armedOn: s.focus }
    go(nx, e),
  }

  // Enter on the focused tab, routed by workspaces.submit! kind policy.
  action enter = all {
    not(s.quit), s.view != 0, acceptsInput(s, s.focus),
    val k = key(s)
    if (s.focus == "main")
      if (not(s.mainBusy))
        all {
          s.mainTurn < MAX_MAIN_TURNS,
          val t = s.mainTurn + 1
          // step appends the prompt, then step-loop injects queued steering
          val inj = s.steerQ.foldl(k.delivered, (acc, q) => acc.append({ typedFor: q, deliveredIn: t }))
          go({ ...k.setDraft(0).appendRow("main", { origin: "main", gen: 0 }),
               mainBusy: true, mainCancelReq: false, mainTurn: t,
               delivered: inj, steerQ: [] }, "submitMain"),
        }
      else
        all {
          s.typedSteer < MAX_STEER,
          go({ ...k.setDraft(0).appendRow("main", { origin: "main", gen: 0 }),
               steerQ: s.steerQ.append(s.mainTurn), typedSteer: s.typedSteer + 1 }, "queueSteer"),
        }
    else if (s.focus == "side")
      if (s.sideBusy or s.live.present)
        // "side agent is busy": error row, draft kept
        go(k.appendRow("side", { origin: "side", gen: s.sideGen }), "sideBusyError")
      else
        go({ ...k.setDraft(0).appendRow("side", { origin: "side", gen: s.sideGen }),
             sideBusy: true,
             live: { present: true, gen: s.sideGen, cancel: false, discard: false } }, "submitSide")
    else
      go({ ...k.setDraft(0), subSteers: s.subSteers + 1 }, "steerSub"),
  }

  // /btw from the main tab: create (or focus) the singleton side tab.
  action openSide = all {
    not(s.quit), s.focus == "main", not(s.sideOpen), s.sideGen < MAX_SIDE_GENS,
    val k = key(s)
    val opened = { ...k, sideOpen: true, sideGen: s.sideGen + 1, sideBusy: false,
                   rec: k.rec.put("side", 0), intended: k.intended.put("side", 0),
                   transcripts: k.transcripts.put("side", []) }
    // entry-for! adopts any same-owner live entry under id :btw
    go(opened.switchTo("side"), "openSide"),
  }

  // Ctrl-W on the side tab: kind close! = side-chat.cancel!, then remove tab.
  action closeSide(fast: bool): bool = all {
    not(s.quit), s.focus == "side", s.sideOpen,
    val k = key(s)
    val disposed =
      if (not(s.live.present)) k
      else if (fast) { ...k, live: NO_LIVE }   // drained within 8 resumes
      else if (FIXES.contains("663")) { ...k, live: NO_LIVE, reaping: k.reaping.append(s.live.gen) }
      else { ...k, live: { ...s.live, cancel: true, discard: true } }  // parked, still live[:btw]
    val gone = { ...disposed, sideOpen: false, sideBusy: false,
                 transcripts: disposed.transcripts.put("side", []) }
    val shown = gone.switchTo("main")
    go({ ...shown, rec: shown.rec.put("side", 0), intended: shown.intended.put("side", 0) },
       if (fast) "closeSideFast" else "closeSideSlow"),
  }

  action closeSub = all {
    not(s.quit), s.focus == "sub", s.subOpen,
    val shown = key(s).switchTo("main")
    // Closing only hides the tab; the run keeps going (docs/tui.md).
    go({ ...shown, subOpen: false, rec: shown.rec.put("sub", 0),
         intended: shown.intended.put("sub", 0) }, "closeSub"),
  }

  // ---- environment: turns emitting events ----
  action mainEmit = all {
    not(s.quit), s.mainBusy,
    go(s.appendRow("main", { origin: "main", gen: 0 }), "mainEmit"),   // with-main!
  }

  action mainFinish(outcome: str): bool = all {
    not(s.quit), s.mainBusy,
    val out = if (s.mainCancelReq) "cancelled" else outcome
    val base = { ...s.appendRow("main", { origin: "main", gen: 0 }),
                 mainBusy: false, mainCancelReq: false, cancelPressed: false }
    val nx =
      if (out == "ok")
        // inject-after-natural-stop!: the turn takes its queued steering
        { ...base, steerQ: [],
          delivered: s.steerQ.foldl(s.delivered, (acc, q) => acc.append({ typedFor: q, deliveredIn: s.mainTurn })) }
      else if (FIXES.contains("662"))
        // fix: lines typed for a turn that died are handed back, not carried over
        { ...base, steerQ: [], returned: s.returned + s.steerQ.length() }
      else base   // error / cancelled: steering stays queued
    go(nx, out),
  }

  // side-chat on-event!: routed by WORKSPACE-ID, i.e. to whatever tab is :btw
  pure def sideDest(st: S): bool =
    st.sideOpen and (not(FIXES.contains("663")) or st.live.gen == st.sideGen)

  action sideEmit = all {
    not(s.quit), s.live.present,
    go(if (sideDest(s)) s.appendRow("side", { origin: "side", gen: s.live.gen }) else s, "sideEmit"),
  }

  action sideFinish = all {
    not(s.quit), s.live.present,
    val ownTab = s.sideOpen and s.live.gen == s.sideGen and not(s.live.discard)
    val withRow = if (sideDest(s)) s.appendRow("side", { origin: "side", gen: s.live.gen }) else s
    go({ ...withRow, live: NO_LIVE, sideBusy: if (ownTab) false else s.sideBusy }, "sideFinish"),
  }

  action reapDone = all {
    not(s.quit), s.reaping.length() > 0,
    go({ ...s, reaping: s.reaping.tail() }, "reapDone"),
  }

  action subStart = all {
    not(s.quit), s.subStatus == "none",
    go({ ...s, subStatus: "running", subOpen: true }, "subStart"),
  }
  action subEmit = all {
    not(s.quit), subRunning(s),
    // sync-subagents!: closed tabs are remembered and not recreated
    go(if (s.subOpen) s.appendRow("sub", { origin: "sub", gen: 0 }) else s, "subEmit"),
  }
  action subFinish = all {
    not(s.quit), subRunning(s),
    go({ ...s, subStatus: "done" }, "subFinish"),
  }

  // /reload: behavior modules swap; tui.state and workspace records persist.
  // A new side_chat OWNER marks an old-owner live turn for cancellation (#441).
  action reload = all {
    not(s.quit), not(s.mainBusy),   // reload requests drain only at an idle tick
    go({ ...s, live: if (s.live.present) { ...s.live, cancel: true } else s.live }, "reload"),
  }

  action stutter = all { s.quit, go(s, "quit") }

  action step = any {
    typeKey,
    nondet t = TABS.oneOf()
    focusKey(t),
    nondet t = TABS.oneOf()
    focusMouse(t),
    ctrlC,
    enter,
    openSide,
    nondet f = Set(true, false).oneOf()
    closeSide(f),
    closeSub,
    mainEmit,
    nondet o = Set("ok", "error").oneOf()
    mainFinish(o),
    sideEmit,
    sideFinish,
    reapDone,
    subStart,
    subEmit,
    subFinish,
    reload,
    stutter,
  }

  // ---- properties ----

  // Ctrl-C only ever cancels (or force-quits over) the turn the focused tab shows.
  val ctrlCActsOnShownTurn =
    val e = ctrlCEffect(s)
    not(s.quit) implies
      ((e == "cancelMain" or e == "forceQuit") implies s.focus == "main") and
      (e == "cancelSide" implies s.focus == "side")

  // When the busy row is up, its hint names what the next Ctrl-C will do.
  val busyHintTruthful =
    (not(s.quit) and busyRowVisible(s)) implies hintOf(ctrlCEffect(s)) == busyHint(s)

  // A second-press quit armed on one tab is never inherited by another.
  val quitArmOnFocusedTab = s.pendingQuit implies s.armedOn == s.focus

  // A steering line reaches the turn it was typed for, or none at all.
  val steeringReachesItsTurn = s.delivered.foldl(true, (ok, d) => ok and d.typedFor == d.deliveredIn)

  // Every line typed while busy is delivered, still queued, or handed back.
  val noSteeringLost =
    s.typedSteer == s.delivered.length() + s.steerQ.length() + s.returned

  // A tab's transcript only holds rows from its own turns (and, for btw,
  // from the tab generation currently open).
  val eventsInOwnTab =
    TABS.forall(t => s.transcripts.get(t).foldl(true, (ok, r) =>
      ok and r.origin == t and (t == "side" implies r.gen == s.sideGen)))

  // The open btw tab is never blocked by a turn it did not start.
  val sideEntryOwned = (s.sideOpen and s.live.present) implies s.live.gen == s.sideGen

  // Closing the btw tab cancels its turn: nothing un-cancelled outlives the tab.
  val closedSideCancelled =
    (s.live.present and s.live.gen != s.sideGen) implies s.live.cancel
  val closedSideIdle = not(s.sideOpen) implies not(s.sideBusy)

  // Per-tab drafts survive focus switches, other tabs' turns, and /reload.
  val draftsPreserved =
    TABS.forall(t => isOpen(s, t) implies draftOf(s, t) == s.intended.get(t))

  val allInvariants = and {
    ctrlCActsOnShownTurn, busyHintTruthful, quitArmOnFocusedTab,
    steeringReachesItsTurn, noSteeringLost, eventsInOwnTab, sideEntryOwned,
    closedSideCancelled, closedSideIdle, draftsPreserved,
  }
}

module current { import tuiTurns(FIXES = Set("660", "661", "662", "663")).* }
module fixed { import tuiTurns(FIXES = Set("660", "661", "662", "663")).* }
module fix660 { import tuiTurns(FIXES = Set("660")).* }
module fix661 { import tuiTurns(FIXES = Set("661")).* }
module fix662 { import tuiTurns(FIXES = Set("662")).* }
module fix663 { import tuiTurns(FIXES = Set("663")).* }
