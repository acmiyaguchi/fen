// Proof model: one presenter pump is fault-isolated (#635) and polls at the
// active cadence while any cooperative work is pending (#637).
//
// Only the state the contract needs: whether the loop runs, whether the
// terminal is raw, whether the transcript holds a row its renderer cannot
// draw, which task sources have pending work (main turn, side turn,
// runtime-tick tasks), and the poll wait before the latest runtime-tick
// resume. Per-row isolation (#635) and the runnable-work OR in
// peek-timeout-ms (#637) are the named fixes.
//
// Integration model: ../../model.qnt.
module pump {
  const FIXES: Set[str]

  pure val ACTIVE_MS = 30
  pure val IDLE_MS = 300
  pure val MAX_BG = 2

  type S = {
    loop: str,        // "running" | "crashed"
    termRaw: bool,
    badRow: bool,
    busy: bool,       // main turn live
    sideAlive: bool,  // side turn live
    bgTasks: int,     // runtime-tick tasks (decide asks, usage refresh, ...)
    lastBgGap: int,   // poll wait before the latest runtime-tick resume
  }

  // One variable per field (Apalache's induction step needs each variable
  // bound by a domain first); `s` is the record view the step functions use.
  var loop: str
  var termRaw: bool
  var badRow: bool
  var busy: bool
  var sideAlive: bool
  var bgTasks: int
  var lastBgGap: int

  val s: S = { loop: loop, termRaw: termRaw, badRow: badRow, busy: busy,
               sideAlive: sideAlive, bgTasks: bgTasks, lastBgGap: lastBgGap }

  action setState(n: S): bool = all {
    loop' = n.loop, termRaw' = n.termRaw, badRow' = n.badRow, busy' = n.busy,
    sideAlive' = n.sideAlive, bgTasks' = n.bgTasks, lastBgGap' = n.lastBgGap,
  }

  action init = setState({ loop: "running", termRaw: true, badRow: false, busy: false,
                      sideAlive: false, bgTasks: 0, lastBgGap: 0 })

  // paint: an unguarded renderer error leaves M.run; presenter shutdown
  // restores the terminal on the way out.
  pure def paint(st: S): S =
    if (st.badRow and not(FIXES.contains("635"))) { ...st, loop: "crashed", termRaw: false }
    else { ...st, badRow: false }

  // peek-timeout-ms
  pure def waitMs(st: S, key: bool): int =
    if (key) 0
    else if (st.busy or st.sideAlive or (FIXES.contains("637") and st.bgTasks > 0)) ACTIVE_MS
    else IDLE_MS

  // One pass: paint, poll, then the runtime-tick tasks, the main turn and
  // the side turn are each resumed once (and may finish).
  action iterate(key: bool, bgFinish: bool, mainFinish: bool, sideFinish: bool): bool = all {
    s.loop == "running",
    val p = paint(s)
    setState(if (p.loop != "running") p
         else
           val w = waitMs(p, key)
           { ...p,
             lastBgGap: if (p.bgTasks > 0) w else p.lastBgGap,
             bgTasks: if (p.bgTasks > 0 and bgFinish) p.bgTasks - 1 else p.bgTasks,
             busy: p.busy and not(mainFinish),
             sideAlive: p.sideAlive and not(sideFinish) }),
  }

  action emitBadRow = all { s.loop == "running", setState({ ...s, badRow: true }) }
  action startBgTask = all { s.loop == "running", s.bgTasks < MAX_BG,
                             setState({ ...s, bgTasks: s.bgTasks + 1 }) }
  action submitMain = all { s.loop == "running", setState({ ...s, busy: true }) }
  action submitSide = all { s.loop == "running", setState({ ...s, sideAlive: true }) }
  action stopped = all { s.loop != "running", setState(s) }

  action step = any {
    nondet key = Set(true, false).oneOf()
    nondet bf = Set(true, false).oneOf()
    nondet mf = Set(true, false).oneOf()
    nondet sf = Set(true, false).oneOf()
    iterate(key, bf, mf, sf),
    emitBadRow, startBgTask, submitMain, submitSide, stopped,
  }

  // ---- properties ----

  val loopSurvivesFaults = s.loop != "crashed"
  val terminalRestoredWhenStopped = s.loop != "running" implies not(s.termRaw)
  val pendingWorkPolledActively = s.lastBgGap <= ACTIVE_MS

  // Inductive strengthening: the properties plus the value domains.
  val pumpInductive = and {
    loop.in(Set("running", "crashed")), termRaw.in(Bool), badRow.in(Bool),
    busy.in(Bool), sideAlive.in(Bool), bgTasks.in(Int), lastBgGap.in(Int),
    bgTasks >= 0, bgTasks <= MAX_BG, lastBgGap >= 0,
    loopSurvivesFaults, terminalRestoredWhenStopped, pendingWorkPolledActively,
  }
}

module current { import pump(FIXES = Set("635", "637")).* }
module fixed { import pump(FIXES = Set("635", "637")).* }
