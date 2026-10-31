// Proof model: per-tab drafts survive focus switches, other tabs' turns,
// close, and /reload.
//
// Only the state the contract needs, no transcripts or turns: the focused
// tab, which tabs are open, `view` (state.*, the focused tab's draft), the
// saved draft of each other tab (workspace records), and a ghost of the
// draft the user last left in each tab. activate! saves the focused view and
// loads the target's (save-view!/load-view!).
//
// No candidate fix touches drafts, so there is one instance: `drafts`.
// Integration model: ../../model.qnt.
module drafts {
  pure val TABS = Set("main", "side", "sub")

  var focus: str
  var sideOpen: bool
  var subOpen: bool
  var view: int           // 0 = empty draft, 1 = some text
  var recMain: int
  var recSide: int
  var recSub: int
  var intMain: int        // ghost: the draft the user left in each tab
  var intSide: int
  var intSub: int

  val rec: str -> int = Map("main" -> recMain, "side" -> recSide, "sub" -> recSub)
  val intended: str -> int = Map("main" -> intMain, "side" -> intSide, "sub" -> intSub)
  pure def openTab(t: str, so: bool, uo: bool): bool =
    if (t == "main") true else if (t == "side") so else uo
  val draftOf: str -> int = TABS.mapBy(t => if (t == focus) view else rec.get(t))

  action init = all {
    focus' = "main", sideOpen' = false, subOpen' = false, view' = 0,
    recMain' = 0, recSide' = 0, recSub' = 0, intMain' = 0, intSide' = 0, intSub' = 0,
  }

  // The user sets the focused tab's draft (typing, clear-draft Ctrl-C, or a
  // submit that empties it).
  action setDraft(v: int): bool = all {
    v != view,
    view' = v,
    intMain' = if (focus == "main") v else intMain,
    intSide' = if (focus == "side") v else intSide,
    intSub' = if (focus == "sub") v else intSub,
    focus' = focus, sideOpen' = sideOpen, subOpen' = subOpen,
    recMain' = recMain, recSide' = recSide, recSub' = recSub,
  }

  // activate! (key or mouse: both paths save and load the views)
  action switchTo(t: str): bool = all {
    t != focus, openTab(t, sideOpen, subOpen),
    focus' = t, view' = rec.get(t),
    recMain' = if (focus == "main") view else recMain,
    recSide' = if (focus == "side") view else recSide,
    recSub' = if (focus == "sub") view else recSub,
    sideOpen' = sideOpen, subOpen' = subOpen,
    intMain' = intMain, intSide' = intSide, intSub' = intSub,
  }

  // /btw from main: a fresh side tab with an empty draft, focused.
  action openSide = all {
    focus == "main", not(sideOpen),
    sideOpen' = true, focus' = "side", view' = 0, recMain' = view, recSide' = 0,
    intSide' = 0,
    subOpen' = subOpen, recSub' = recSub, intMain' = intMain, intSub' = intSub,
  }

  // A subagent run opens its tab (not focused) with an empty draft.
  action subStart = all {
    not(subOpen), focus != "sub",
    subOpen' = true, recSub' = 0, intSub' = 0,
    focus' = focus, sideOpen' = sideOpen, view' = view, recMain' = recMain,
    recSide' = recSide, intMain' = intMain, intSide' = intSide,
  }

  // Ctrl-W on the side or sub tab: the tab goes, main is focused.
  action closeTab = all {
    focus != "main",
    focus' = "main", view' = recMain,
    sideOpen' = (sideOpen and focus != "side"), subOpen' = (subOpen and focus != "sub"),
    recSide' = if (focus == "side") 0 else recSide, intSide' = if (focus == "side") 0 else intSide,
    recSub' = if (focus == "sub") 0 else recSub, intSub' = if (focus == "sub") 0 else intSub,
    recMain' = recMain, intMain' = intMain,
  }

  // Other tabs' turns emitting and /reload touch no draft (ensure! fills
  // only missing fields): a stutter for this contract.
  action otherActivity = all {
    focus' = focus, sideOpen' = sideOpen, subOpen' = subOpen, view' = view,
    recMain' = recMain, recSide' = recSide, recSub' = recSub,
    intMain' = intMain, intSide' = intSide, intSub' = intSub,
  }

  action step = any {
    nondet v = Set(0, 1).oneOf()
    setDraft(v),
    nondet t = TABS.oneOf()
    switchTo(t),
    openSide, subStart, closeTab, otherActivity,
  }

  // Per-tab drafts are what the user left in them.
  val draftsPreserved =
    TABS.forall(t => openTab(t, sideOpen, subOpen) implies draftOf.get(t) == intended.get(t))

  // Inductive strengthening: the focused tab is open, and every unfocused
  // tab's saved draft is its intended one (closed tabs hold 0 for both).
  val draftsInductive = and {
    focus.in(TABS), sideOpen.in(Bool), subOpen.in(Bool), view.in(Set(0, 1)),
    recMain.in(Set(0, 1)), recSide.in(Set(0, 1)), recSub.in(Set(0, 1)),
    intMain.in(Set(0, 1)), intSide.in(Set(0, 1)), intSub.in(Set(0, 1)),
    openTab(focus, sideOpen, subOpen),
    view == intended.get(focus),
    TABS.forall(t => t != focus implies rec.get(t) == intended.get(t)),
    draftsPreserved,
  }
}
