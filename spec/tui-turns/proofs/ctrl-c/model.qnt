// Proof model: Ctrl-C acts on the turn the focused tab shows (#660), and a
// second-press quit armed on one tab is never inherited by another (#661).
//
// Only the state the contract needs: the focused tab, which tabs are open,
// whether each tab's turn runs, whether each tab has a draft, and the main
// session's Ctrl-C ladder (cancel-pressed?, pending-quit? and the tab it was
// armed on). No transcripts, no steering, no generations.
//
// Integration model: ../../model.qnt.
module ctrlC {
  const FIXES: Set[str]

  var focus: str          // "main" | "side" | "sub"
  var sideOpen: bool
  var subOpen: bool
  var mainBusy: bool
  var sideBusy: bool
  var subRunning: bool
  var dMain: bool         // the tab has a draft
  var dSide: bool
  var dSub: bool
  var cancelPressed: bool
  var pendingQuit: bool
  var armedOn: str        // "" | tab
  var quit: bool

  pure val TABS = Set("main", "side", "sub")

  val draftHere = if (focus == "main") dMain else if (focus == "side") dSide else dSub
  val sideRunning = sideOpen and sideBusy
  val allowsSubmit = if (focus == "main") true else if (focus == "side") not(sideRunning) else false

  // input.handle-key, KEY_CTRL_C branch
  val ctrlCEffect =
    val ladder =
      if (allowsSubmit and draftHere and not(pendingQuit)) "clearDraft"
      else if (pendingQuit) "quit"
      else "arm"
    if (focus == "side" and sideRunning) "cancelSide"
    else if (FIXES.contains("660") and focus != "main") ladder
    else if (mainBusy and cancelPressed) "forceQuit"
    else if (mainBusy) "cancelMain"
    else ladder

  // panels/busy.fnl
  val busyRowVisible =
    if (focus == "main") mainBusy else if (focus == "side") sideRunning else subOpen and subRunning
  val busyHint =
    if (focus == "main") (if (cancelPressed) "forceQuit" else "cancel")
    else if (focus == "side") "cancel"
    else "none"
  pure def hintOf(e: str): str =
    if (e == "cancelMain" or e == "cancelSide") "cancel" else if (e == "forceQuit") "forceQuit" else "none"

  pure def isOpenTab(t: str, so: bool, uo: bool): bool =
    if (t == "main") true else if (t == "side") so else uo

  action init = all {
    focus' = "main", sideOpen' = false, subOpen' = false, mainBusy' = false,
    sideBusy' = false, subRunning' = false, dMain' = false, dSide' = false, dSub' = false,
    cancelPressed' = false, pendingQuit' = false, armedOn' = "", quit' = false,
  }

  // Frame for the presenter ladder and the per-tab state.
  action keepTabs = all {
    sideOpen' = sideOpen, subOpen' = subOpen, mainBusy' = mainBusy, sideBusy' = sideBusy,
    subRunning' = subRunning,
  }
  action keepDrafts = all { dMain' = dMain, dSide' = dSide, dSub' = dSub }

  action ctrlCKey = all {
    not(quit),
    val e = ctrlCEffect
    all {
      keepTabs,
      focus' = focus,
      dMain' = if (e == "clearDraft" and focus == "main") false else dMain,
      dSide' = if (e == "clearDraft" and focus == "side") false else dSide,
      dSub' = if (e == "clearDraft" and focus == "sub") false else dSub,
      cancelPressed' = (cancelPressed or e == "cancelMain"),
      pendingQuit' = (if (e == "arm") true else pendingQuit),
      armedOn' = if (e == "arm") focus else armedOn,
      quit' = (e == "quit" or e == "forceQuit"),
    },
  }

  // Every key except Ctrl-C clears pending-quit? (top of handle-key); the
  // tab click path calls activate! directly (#661 fix: activate! disarms).
  action focusTo(t: str, byMouse: bool): bool = all {
    not(quit), t != focus, isOpenTab(t, sideOpen, subOpen),
    focus' = t,
    pendingQuit' = (if (byMouse and not(FIXES.contains("661"))) pendingQuit else false),
    keepTabs, keepDrafts, cancelPressed' = cancelPressed, armedOn' = armedOn, quit' = quit,
  }

  // Any other key on the focused tab: typing (a draft appears) or Enter with a
  // draft (submits on main/side when idle). Both disarm the pending quit.
  action typeKey = all {
    not(quit), not(focus == "sub" and not(subRunning)),
    focus' = focus,
    dMain' = (dMain or focus == "main"), dSide' = (dSide or focus == "side"),
    dSub' = (dSub or focus == "sub"),
    pendingQuit' = false,
    keepTabs, cancelPressed' = cancelPressed, armedOn' = armedOn, quit' = quit,
  }

  action submitMain = all {
    not(quit), focus == "main", dMain, not(mainBusy),
    mainBusy' = true, dMain' = false, pendingQuit' = false,
    focus' = focus, sideOpen' = sideOpen, subOpen' = subOpen, sideBusy' = sideBusy,
    subRunning' = subRunning, dSide' = dSide, dSub' = dSub,
    cancelPressed' = cancelPressed, armedOn' = armedOn, quit' = quit,
  }

  action submitSide = all {
    not(quit), focus == "side", dSide, not(sideBusy),
    sideBusy' = true, dSide' = false, pendingQuit' = false,
    focus' = focus, sideOpen' = sideOpen, subOpen' = subOpen, mainBusy' = mainBusy,
    subRunning' = subRunning, dMain' = dMain, dSub' = dSub,
    cancelPressed' = cancelPressed, armedOn' = armedOn, quit' = quit,
  }

  // /btw from main (a key, so it disarms) opens and focuses the side tab.
  action openSide = all {
    not(quit), focus == "main", not(sideOpen),
    focus' = "side", sideOpen' = true, sideBusy' = false, dSide' = false, pendingQuit' = false,
    subOpen' = subOpen, mainBusy' = mainBusy, subRunning' = subRunning, dMain' = dMain,
    dSub' = dSub, cancelPressed' = cancelPressed, armedOn' = armedOn, quit' = quit,
  }

  // Ctrl-W on the side or sub tab (a key) closes it and focuses main.
  action closeTab = all {
    not(quit), focus != "main",
    focus' = "main",
    sideOpen' = (sideOpen and focus != "side"), sideBusy' = (sideBusy and focus != "side"),
    subOpen' = (subOpen and focus != "sub"),
    dSide' = (dSide and focus != "side"), dSub' = (dSub and focus != "sub"),
    pendingQuit' = false,
    mainBusy' = mainBusy, subRunning' = subRunning, dMain' = dMain,
    cancelPressed' = cancelPressed, armedOn' = armedOn, quit' = quit,
  }

  // Environment: turns end, a subagent run starts or ends.
  action mainEnds = all {
    not(quit), mainBusy, mainBusy' = false, cancelPressed' = false,
    focus' = focus, sideOpen' = sideOpen, subOpen' = subOpen, sideBusy' = sideBusy,
    subRunning' = subRunning, keepDrafts, pendingQuit' = pendingQuit, armedOn' = armedOn,
    quit' = quit,
  }
  action sideEnds = all {
    not(quit), sideBusy, sideBusy' = false,
    focus' = focus, sideOpen' = sideOpen, subOpen' = subOpen, mainBusy' = mainBusy,
    subRunning' = subRunning, keepDrafts, cancelPressed' = cancelPressed,
    pendingQuit' = pendingQuit, armedOn' = armedOn, quit' = quit,
  }
  action subStarts = all {
    not(quit), not(subRunning), not(subOpen), subRunning' = true, subOpen' = true, dSub' = false,
    focus' = focus, sideOpen' = sideOpen, mainBusy' = mainBusy, sideBusy' = sideBusy,
    dMain' = dMain, dSide' = dSide, cancelPressed' = cancelPressed,
    pendingQuit' = pendingQuit, armedOn' = armedOn, quit' = quit,
  }
  action subEnds = all {
    not(quit), subRunning, subRunning' = false,
    focus' = focus, sideOpen' = sideOpen, subOpen' = subOpen, mainBusy' = mainBusy,
    sideBusy' = sideBusy, keepDrafts, cancelPressed' = cancelPressed,
    pendingQuit' = pendingQuit, armedOn' = armedOn, quit' = quit,
  }
  action stopped = all {
    quit, keepTabs, keepDrafts, focus' = focus, cancelPressed' = cancelPressed,
    pendingQuit' = pendingQuit, armedOn' = armedOn, quit' = quit,
  }

  action step = any {
    ctrlCKey,
    nondet t = TABS.oneOf()
    nondet m = Bool.oneOf()
    focusTo(t, m),
    typeKey, submitMain, submitSide, openSide, closeTab,
    mainEnds, sideEnds, subStarts, subEnds, stopped,
  }

  // ---- properties ----

  val ctrlCActsOnShownTurn =
    not(quit) implies
      (((ctrlCEffect == "cancelMain" or ctrlCEffect == "forceQuit") implies focus == "main") and
       (ctrlCEffect == "cancelSide" implies focus == "side"))

  val busyHintTruthful = (not(quit) and busyRowVisible) implies hintOf(ctrlCEffect) == busyHint

  val quitArmOnFocusedTab = pendingQuit implies armedOn == focus

  // Inductive strengthening: domains, the focused tab is open, cancel-pressed?
  // only while main runs, and the properties.
  val ctrlCInductive = and {
    focus.in(TABS), sideOpen.in(Bool), subOpen.in(Bool), mainBusy.in(Bool), sideBusy.in(Bool),
    subRunning.in(Bool), dMain.in(Bool), dSide.in(Bool), dSub.in(Bool),
    cancelPressed.in(Bool), pendingQuit.in(Bool), armedOn.in(Set("", "main", "side", "sub")),
    quit.in(Bool),
    isOpenTab(focus, sideOpen, subOpen),
    cancelPressed implies mainBusy,
    ctrlCActsOnShownTurn, busyHintTruthful, quitArmOnFocusedTab,
  }
}

module current { import ctrlC(FIXES = Set("660", "661")).* }
module fixed { import ctrlC(FIXES = Set("660", "661")).* }
module fix660 { import ctrlC(FIXES = Set("660")).* }
module fix661 { import ctrlC(FIXES = Set("661")).* }
