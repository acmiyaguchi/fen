// Proof model: the presenter's Ctrl-C arm belongs to one turn (#636).
//
// Only the state the contract needs: the main turn (kind, generation, cancel
// request), the queued reload request, and the arm (cancel-pressed?, plus the
// generation it was aimed at as a ghost). One `iterate` keeps M.run's phase
// order, which #636 depends on: input (the Ctrl-C ladder) runs before on-tick
// (resume, finalize, idle-boundary start), and the cancel-pressed? reset runs
// last, at the bottom of the loop. `pumpModal` is the select overlay's pump:
// on-tick without the bottom reset.
//
// Integration model: ../../model.qnt (paint, poll, side chat, background tasks).
module cancelArm {
  const FIXES: Set[str]

  type S = {
    kind: str,          // "none" | "agent" | "reload"
    gen: int,           // state.turn-id
    cancelReq: bool,    // state.cancel-requested?
    reloadQueued: bool, // reload_request queue non-empty
    armed: bool,        // tui state.cancel-pressed?
    pressGen: int,      // ghost: the turn the first Ctrl-C was aimed at
    quit: str,          // "" | "forceOwn" | "forceFresh"
  }

  // One variable per field (Apalache's induction step needs each variable
  // bound by a domain first); `s` is the record view the step functions use.
  var kind: str
  var gen: int
  var cancelReq: bool
  var reloadQueued: bool
  var armed: bool
  var pressGen: int
  var quit: str

  val s: S = { kind: kind, gen: gen, cancelReq: cancelReq, reloadQueued: reloadQueued,
               armed: armed, pressGen: pressGen, quit: quit }

  action setState(n: S): bool = all {
    kind' = n.kind, gen' = n.gen, cancelReq' = n.cancelReq,
    reloadQueued' = n.reloadQueued, armed' = n.armed, pressGen' = n.pressGen,
    quit' = n.quit,
  }

  action init = setState({ kind: "none", gen: 0, cancelReq: false, reloadQueued: false,
                      armed: false, pressGen: 0, quit: "" })

  pure def busy(st: S): bool = st.kind != "none"

  // input.fnl handle-key, Ctrl-C and Enter
  pure def input(st: S, ev: str): S =
    if (ev == "ctrlC" and busy(st) and st.armed)
      { ...st, quit: if (st.pressGen == st.gen) "forceOwn" else "forceFresh" }
    else if (ev == "ctrlC" and busy(st))
      { ...st, cancelReq: true, armed: true, pressGen: st.gen }
    else if (ev == "submit" and not(busy(st)))
      { ...st, kind: "agent", gen: st.gen + 1, cancelReq: false }
    else st

  // interactive.fnl on-tick: one resume, finalize on death, then the idle
  // boundary may start the next turn in the same call.
  pure def onTick(st: S, outcome: str, nextTurn: bool): S =
    if (st.quit != "" or not(busy(st))) st
    else
      val cancelled = st.kind == "agent" and st.cancelReq
      val dies = cancelled or outcome == "finish"
      if (not(dies)) st
      else
        // fixed (#636): finalizing a turn disarms the ladder for it
        val ended = { ...st, kind: "none", cancelReq: false,
                      armed: if (FIXES.contains("636")) false else st.armed }
        if (ended.reloadQueued)
          { ...ended, kind: "reload", gen: st.gen + 1, reloadQueued: false }
        else if (nextTurn and not(cancelled))
          { ...ended, kind: "agent", gen: st.gen + 1 }
        else ended

  // M.run bottom-of-loop reset
  pure def bottom(st: S): S =
    val clear =
      if (FIXES.contains("636")) st.armed and (not(busy(st)) or st.pressGen != st.gen)
      else st.armed and not(busy(st))
    if (st.quit == "" and clear) { ...st, armed: false } else st

  action iterate(ev: str, outcome: str, nextTurn: bool): bool = all {
    s.quit == "",
    setState(bottom(onTick(input(s, ev), outcome, nextTurn))),
  }

  action pumpModal(outcome: str, nextTurn: bool): bool = all {
    s.quit == "",
    setState(onTick(s, outcome, nextTurn)),
  }

  // The agent's `reload` tool queues a deferred request mid-turn.
  action agentQueuesReload = all {
    s.quit == "", s.kind == "agent", not(s.reloadQueued),
    setState({ ...s, reloadQueued: true }),
  }

  action stopped = all { s.quit != "", setState(s) }

  action step = any {
    nondet ev = Set("none", "ctrlC", "submit").oneOf()
    nondet outcome = Set("yield", "finish").oneOf()
    nondet nextTurn = Set(true, false).oneOf()
    iterate(ev, outcome, nextTurn),
    nondet outcome = Set("yield", "finish").oneOf()
    nondet nextTurn = Set(true, false).oneOf()
    pumpModal(outcome, nextTurn),
    agentQueuesReload,
    stopped,
  }

  // ---- properties ----

  // The armed first press refers to the turn that is running now.
  val cancelArmMatchesTurn = s.armed implies (busy(s) and s.pressGen == s.gen)

  // A second Ctrl-C force-quits only the turn the first one was aimed at.
  val forceQuitOnlyOnArmedTurn = s.quit != "forceFresh"

  // Inductive strengthening: the two properties plus the value domains
  // (Apalache's induction step starts from any well-typed state).
  val armInductive = and {
    kind.in(Set("none", "agent", "reload")), gen.in(Int), cancelReq.in(Bool),
    reloadQueued.in(Bool), armed.in(Bool), pressGen.in(Int),
    quit.in(Set("", "forceOwn", "forceFresh")),
    s.cancelReq implies busy(s),
    cancelArmMatchesTurn,
    forceQuitOnlyOnArmedTurn,
  }
}

module current { import cancelArm(FIXES = Set()).* }
module fixed { import cancelArm(FIXES = Set("636")).* }
