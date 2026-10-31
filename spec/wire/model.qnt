// Model of the live-subagent wire protocol: one parent (the `subagent`
// extension) and one child (`fen --presenter rpc`) talking over two
// append-only JSONL files.
//
//   control file  parent appends controls (seq 1 = the task `prompt`, written
//                 before spawn); the child reads every unread line at the top
//                 of its loop and answers each with a control-ack, then acts
//                 through `wire_session.decide`
//   event file    child appends events; the parent reads them some lines at a
//                 time and mirrors the run state from events alone
//                 (`decide` on each non-rejected ack, `advance` on
//                 turn-complete, `exit` sets the terminal state)
//
// Child: packages/util/src/fen/util/wire_session.fnl (table),
//        extensions/adapters/presenters/rpc/init.fnl (apply-control!,
//        perform!, turn-ended!, finish!, drop-queued!, take-ref!,
//        check-deadline!, result-line/spill-final-text).
// Parent: extensions/behaviors/companions/subagent/channel.fnl (send!,
//        mirror!, idle?), init.fnl (drive!, maybe-finalize!, finish!,
//        result-final-text, send-cancel!/arm-kill!).
//
// Abstractions: only `steer` is modelled among queued inputs (the in-tree
// parent never sends `follow-up`); the steering service queue and the
// presenter's `pending` ref FIFO are kept separately because they disagree
// on empty text. Each child action is atomic (a whole poll batch, a whole
// turn end); the parent reads 1..n new lines per poll. `long` = the answer
// overflows one line and is spilled to a temp file; `crashPlan` = the child
// dies after spilling and before the result line lands.
module wire {
  // Candidate fixes by issue number: "664" (ack the whole batch, hold
  // doomed steers, report unresolved steers at settle), "665" (finalize in
  // ready keeps the answer), "666" (reject empty steers), "667" (the parent
  // names and removes the spill file).
  const FIXES: Set[str]

  pure val MAX_STEERS = 2
  pure val MAX_TOOLCALLS = 2
  pure val MAX_TURNS = 3
  pure val TERMINAL = Set("done", "cancelled", "failed", "timed-out")

  type Item = { ref: int, empty: bool }
  type Ctl = { seq: int, kind: str, empty: bool }
  // kind: ready | ack | turnStarted | turnComplete | injected | dropped |
  //       result | exit | answer | toolCall
  type Ev = { kind: str, ref: int, status: str, refs: List[int] }
  type Entry = { status: str, act: str, next: str }
  type Adv = { ok: bool, act: str, next: str }

  type Child = {
    st: str, active: bool, final: bool, interrupt: bool,
    q: List[Item],        // steering service queue
    pending: List[Item],  // presenter's ref FIFO (ch.pending.steering)
    accepted: Set[int],   // refs of queued (accepted) steers, ghost
    exited: bool, crashed: bool, exitPending: str,
    out: List[Ev], ctlRead: int, turns: int, toolCalls: int,
    lastNatural: bool, replaced: bool, deadlineFired: bool, fatalFired: bool,
    long: bool, crashPlan: bool, spilled: bool,
  }

  type Req = { seq: int, empty: bool }   // a user steer; seq 0 = not sent yet

  type Parent = {
    st: str, seq: int, ctlFile: List[Ctl], sentKind: int -> str,
    unacked: Set[int], read: int,
    exitSeen: bool, gotResult: bool, budgetHit: bool, answerSeen: bool,
    closeSent: bool, cancelSent: bool, finalizeSent: bool, cancelReq: bool,
    reqs: List[Req], reportedSeqs: Set[int], localReported: Set[int],
    doomed: bool,
  }

  pure def ev(k: str): Ev = { kind: k, ref: 0, status: "", refs: [] }
  pure def acc(a: str, n: str): Entry = { status: "accepted", act: a, next: n }
  pure def app(n: str): Entry = { status: "applied", act: "none", next: n }
  pure val REJ: Entry = { status: "rejected", act: "none", next: "" }
  pure def go(a: str, n: str): Adv = { ok: true, act: a, next: n }
  pure val NOADV: Adv = { ok: false, act: "none", next: "" }

  // ---- wire_session.decide / advance ----
  pure def decide(st: str, kind: str, empty: bool): Entry =
    if (TERMINAL.contains(st)) REJ
    else if (kind == "cancel") acc("abort", "cancelled")
    else if (st == "starting") REJ
    // fix: an empty steer can never be injected or matched to its ref
    else if (FIXES.contains("666") and empty and kind == "steer") REJ
    else if (st == "ready")
      if (kind == "prompt" or kind == "steer") acc("start-turn", "running")
      // fix: a finalize that finds the turn already over keeps its answer
      else if (kind == "finalize")
        (if (FIXES.contains("665")) acc("finish", "done") else acc("start-finalize-turn", "finalizing"))
      else if (kind == "close") acc("finish", "done")
      else REJ
    else if (st == "running")
      if (kind == "steer") acc("queue", "running")
      else if (kind == "finalize") acc("interrupt-turn", "finalizing")
      else if (kind == "close") acc("none", "closing")
      else REJ
    else if (st == "closing")
      if (kind == "finalize") acc("interrupt-turn", "finalizing")
      else if (kind == "close") app("closing")
      else REJ
    else if (st == "finalizing")
      if (kind == "finalize" or kind == "close") app("finalizing")
      else REJ
    else REJ

  pure def advance(st: str, e: str): Adv =
    if (TERMINAL.contains(st))
      if (e == "turn-done" or e == "final-turn-done") go("exit", st)
      else if (e == "deadline" or e == "fatal") go("abort", st)
      else NOADV
    else if (e == "deadline") go("abort", "timed-out")
    else if (e == "fatal") go("abort", "failed")
    else if (st == "starting" and e == "started") go("none", "ready")
    else if (st == "running" and e == "turn-done") go("none", "ready")
    else if (st == "closing" and e == "turn-done") go("finish", "done")
    else if (st == "finalizing" and e == "turn-done") go("start-finalize-turn", "finalizing")
    else if (st == "finalizing" and e == "final-turn-done") go("finish", "done")
    else NOADV

  // ---- child presenter ----
  pure def emit(c: Child, e: Ev): Child = { ...c, out: c.out.append(e) }

  // drop-queued!: n counts the service queue, refs come from `pending`.
  pure def dropQueued(c: Child): Child =
    val refs = c.pending.foldl([], (a, it) => a.append(it.ref))
    val c1 = { ...c, pending: [] }
    if (c1.q.length() > 0) { ...c1, q: [] }.emit({ ...ev("dropped"), refs: refs })
    else c1

  pure def exitNow(c: Child, status: str): Child =
    if (c.exited or c.crashed) c
    else { ...dropQueued(c).emit({ ...ev("exit"), status: status }), exited: true }

  // finish!: drop notice, then (maybe spill) result, then exit done.
  pure def finishNow(c: Child): Child =
    val c1 = dropQueued(c)
    val c2 = { ...c1, spilled: c1.spilled or c1.long }
    if (c2.long and c2.crashPlan) { ...c2, crashed: true }
    else exitNow(c2.emit(ev("result")), "done")

  pure def flush(c: Child): Child =
    if (c.exitPending == "finish") finishNow({ ...c, exitPending: "" })
    else if (c.exitPending == "exit") exitNow({ ...c, exitPending: "" }, c.st)
    else c

  pure def startTurn(c: Child, final: bool): Child =
    { ...c, active: true, final: final, interrupt: false, turns: c.turns + 1 }
      .emit(ev("turnStarted"))

  pure def perform(c: Child, act: str, ctl: Ctl): Child =
    if (act == "start-turn") startTurn(c, false)
    else if (act == "start-finalize-turn") startTurn(c, true)
    else if (act == "queue")
      val it = { ref: ctl.seq, empty: ctl.empty }
      { ...c, q: c.q.append(it), pending: c.pending.append(it),
              accepted: c.accepted.union(Set(ctl.seq)) }
    else if (act == "interrupt-turn")
      (if (c.active) { ...c, interrupt: true } else c)
    else if (act == "abort")
      (if (c.active) { ...c, interrupt: true } else { ...c, exitPending: "exit" })
    else if (act == "exit") { ...c, exitPending: "exit" }
    else if (act == "finish") { ...c, exitPending: "finish" }
    else c

  pure val NOCTL: Ctl = { seq: 0, kind: "", empty: false }

  // apply-control!: one ack, then the effect. Nothing at all once exited.
  pure def applyControl(c: Child, ctl: Ctl): Child =
    if (c.exited or c.crashed) c
    else
      val e = decide(c.st, ctl.kind, ctl.empty)
      val c1 = c.emit({ ...ev("ack"), ref: ctl.seq, status: e.status })
      if (e.status == "rejected") c1
      else
        val c2 = if (ctl.kind == "finalize" and e.status == "accepted") dropQueued(c1) else c1
        val repl = e.act == "start-finalize-turn" and c.st == "ready" and c.lastNatural
        perform({ ...c2, st: e.next, replaced: c2.replaced or repl }, e.act, ctl)

  // poll-controls!: today an exit mid-batch skips the rest of the batch
  // unanswered; the fix defers the exit until every read line is acked.
  pure def applyBatch(c: Child, batch: List[Ctl]): Child =
    if (FIXES.contains("664")) flush(batch.foldl(c, (a, x) => applyControl(a, x)))
    else batch.foldl(c, (a, x) => flush(applyControl(a, x)))

  // turn-ended!: a turn that threw (`state.turn-error`) is `fatal`.
  pure def turnEndedWith(c: Child, natural: bool, threw: bool): Child =
    val c0 = if (natural) c.emit(ev("answer")) else c
    val c1 = { ...c0, active: false, interrupt: false, lastNatural: natural }
               .emit(ev("turnComplete"))
    val a = advance(c1.st, if (threw) "fatal" else if (c.final) "final-turn-done" else "turn-done")
    val c2 = if (a.ok) perform({ ...c1, st: a.next }, a.act, NOCTL) else c1
    val c3 = flush(c2)
    if (not(c3.exited) and not(c3.active) and TERMINAL.contains(c3.st)) exitNow(c3, c3.st)
    else c3

  pure def turnEnded(c: Child, natural: bool): Child = turnEndedWith(c, natural, false)

  // take-ref!: pop the FIFO head only when its text equals the injected text.
  // Text identity: a non-empty steer's text is its ref, an empty one is "".
  pure def inject(c: Child): Child =
    val it = c.q[0]
    val c1 = { ...c, q: c.q.slice(1, c.q.length()) }
    if (it.empty) c1   // inject-user-lines! skips "" silently
    else
      val fifo = c1.pending
      if (fifo.length() > 0 and not(fifo[0].empty) and fifo[0].ref == it.ref)
        { ...c1, pending: fifo.slice(1, fifo.length()) }
          .emit({ ...ev("injected"), ref: it.ref })
      else c1.emit({ ...ev("injected"), ref: 0 })

  // ---- parent ----
  pure def mirror(p: Parent, e: Ev): Parent =
    if (e.kind == "ready") (if (p.st == "starting") { ...p, st: "ready" } else p)
    else if (e.kind == "ack")
      if (p.unacked.contains(e.ref))
        val k = p.sentKind.get(e.ref)
        val p1 = { ...p, unacked: p.unacked.exclude(Set(e.ref)) }
        if (e.status != "rejected")
          val d = decide(p1.st, k, false)
          if (d.next != "") { ...p1, st: d.next } else p1
        else if (k == "steer") { ...p1, reportedSeqs: p1.reportedSeqs.union(Set(e.ref)) }
        else p1
      else p
    else if (e.kind == "turnStarted") (if (p.st == "ready") { ...p, st: "running" } else p)
    else if (e.kind == "turnComplete")
      val a = advance(p.st, "turn-done")
      if (a.ok and not(TERMINAL.contains(a.next))) { ...p, st: a.next } else p
    else if (e.kind == "injected")
      (if (e.ref > 0) { ...p, reportedSeqs: p.reportedSeqs.union(Set(e.ref)) } else p)
    else if (e.kind == "dropped")
      { ...p, reportedSeqs: e.refs.foldl(p.reportedSeqs, (s, r) => s.union(Set(r))) }
    else if (e.kind == "result") { ...p, gotResult: true }
    else if (e.kind == "exit") { ...p, exitSeen: true, st: e.status }
    else if (e.kind == "answer") { ...p, answerSeen: true }
    else if (e.kind == "toolCall") { ...p, budgetHit: true }
    else p

  // channel.poll stops at `exit`.
  pure def readUpTo(p: Parent, out: List[Ev], upto: int): Parent =
    range(p.read, upto).foldl(p, (a, i) =>
      if (a.exitSeen) { ...a, read: i + 1 } else { ...mirror(a, out[i]), read: i + 1 })

  pure def send(p: Parent, kind: str, empty: bool): Parent =
    val s = p.seq + 1
    val doomedNow = kind == "steer" and
                    (p.closeSent or not(Set("starting", "ready", "running").contains(p.st)))
    { ...p, seq: s, ctlFile: p.ctlFile.append({ seq: s, kind: kind, empty: empty }),
            sentKind: p.sentKind.put(s, kind), unacked: p.unacked.union(Set(s)),
            doomed: p.doomed or doomedNow,
            closeSent: p.closeSent or kind == "close",
            cancelSent: p.cancelSent or kind == "cancel",
            finalizeSent: p.finalizeSent or kind == "finalize" }

  // fix: hold a steer the mirror knows can no longer apply; settle reports it.
  pure def canSteer(p: Parent): bool =
    not(FIXES.contains("664")) or (not(p.closeSent) and Set("starting", "ready", "running").contains(p.st))

  // drive!
  pure def drive(p: Parent): Parent =
    if (p.exitSeen) p
    else if (p.cancelReq) (if (p.cancelSent) p else p.send("cancel", false))
    else
      val p1 = range(0, p.reqs.length()).foldl(p, (a, i) =>
        if (a.reqs[i].seq == 0 and canSteer(a))
          val a2 = a.send("steer", a.reqs[i].empty)
          { ...a2, reqs: a2.reqs.replaceAt(i, { ...a.reqs[i], seq: a2.seq }) }
        else a)
      // maybe-finalize!: only when the mirror says running
      val p2 = if (p1.budgetHit and not(p1.answerSeen) and not(p1.finalizeSent)
                   and p1.st == "running") p1.send("finalize", false) else p1
      // idle? -> close
      if (not(p2.closeSent) and p2.st == "ready" and p2.unacked == Set())
        p2.send("close", false)
      else p2

  // ---- state ----
  var c: Child
  var p: Parent
  var settled: bool
  var removals: int
  var lastAction: str
  // Which environment disruption this trace may use (at most one kind), so
  // random simulation spends its steps on protocol interleavings.
  var scenario: str

  pure val SCENARIOS = Set("none", "crash", "deadline", "fatal", "cancel", "error",
                           "empty", "long", "longCrash", "external")

  // initWith/parentPollK take the nondeterministic choices as arguments, so
  // witnesses.qnt can replay a counterexample step by step.
  action initWith(sc: str): bool = all {
    scenario' = sc,
      c' = { st: "starting", active: false, final: false, interrupt: false,
             q: [], pending: [], accepted: Set(), exited: false, crashed: false,
             exitPending: "", out: [], ctlRead: 0, turns: 0, toolCalls: 0,
             lastNatural: false, replaced: false, deadlineFired: false, fatalFired: false,
             long: false, crashPlan: false, spilled: false },
      // the task prompt is appended before the child is spawned
      p' = { st: "starting", seq: 1, ctlFile: [{ seq: 1, kind: "prompt", empty: false }],
             sentKind: Map(1 -> "prompt"), unacked: Set(1), read: 0,
             exitSeen: false, gotResult: false, budgetHit: false, answerSeen: false,
             closeSent: false, cancelSent: false, finalizeSent: false,
             cancelReq: false, reqs: [], reportedSeqs: Set(), localReported: Set(),
             doomed: false },
      settled' = false, removals' = 0, lastAction' = "init",
  }

  action init = { nondet sc = SCENARIOS.oneOf() initWith(sc) }

  pure def alive(x: Child): bool = not(x.exited) and not(x.crashed)

  action childDo(nc: Child, name: str): bool = all {
    c' = nc, p' = p, settled' = settled, removals' = removals, lastAction' = name,
    scenario' = scenario,
  }

  action parentDo(np: Parent, name: str): bool = all {
    p' = np, c' = c, settled' = settled, removals' = removals, lastAction' = name,
    scenario' = scenario,
  }

  action childStart = all {
    alive(c), c.st == "starting",
    childDo({ ...c.emit(ev("ready")), st: "ready" }, "childStart"),
  }

  action childPoll = all {
    alive(c), c.st != "starting", c.ctlRead < p.ctlFile.length(),
    val batch = p.ctlFile.slice(c.ctlRead, p.ctlFile.length())
    childDo(applyBatch({ ...c, ctlRead: p.ctlFile.length() }, batch), "childPoll"),
  }

  action childInject = all {
    alive(c), c.active, not(c.interrupt), c.q.length() > 0,
    childDo(inject(c), "childInject"),
  }

  action childToolCall = all {
    alive(c), c.active, not(c.final), not(c.interrupt), c.toolCalls < MAX_TOOLCALLS,
    childDo({ ...c, toolCalls: c.toolCalls + 1 }.emit(ev("toolCall")), "childToolCall"),
  }

  // A natural stop only ends the turn when nothing is queued.
  action childAnswer = all {
    alive(c), c.active, not(c.interrupt), c.q.length() == 0,
    childDo(turnEnded(c, true), "childAnswer"),
  }

  // A provider error ends the turn with input still queued.
  action childTurnError = all {
    scenario == "error", alive(c), c.active, not(c.interrupt),
    childDo(turnEnded(c, false), "childTurnError"),
  }

  // An interrupted turn unwinds at its next yield.
  action childUnwind = all {
    alive(c), c.active, c.interrupt,
    childDo(turnEnded(c, false), "childUnwind"),
  }

  action childDeadline = all {
    scenario == "deadline", alive(c), not(c.deadlineFired), not(TERMINAL.contains(c.st)), c.st != "starting",
    val a = advance(c.st, "deadline")
    childDo(flush(perform({ ...c, st: a.next, deadlineFired: true }, a.act, NOCTL)),
            "childDeadline"),
  }

  // fatal!: an unrecoverable error outside a turn (a control line of another
  // wire version, the control file truncated below the read offset).
  action childFatal = all {
    scenario == "fatal", alive(c), not(c.fatalFired), not(TERMINAL.contains(c.st)), c.st != "starting",
    val a = advance(c.st, "fatal")
    childDo(flush(perform({ ...c, st: a.next, fatalFired: true }, a.act, NOCTL)),
            "childFatal"),
  }

  // A turn that throws: turn-ended! sees `state.turn-error` and calls fatal!.
  action childTurnThrow = all {
    scenario == "fatal", alive(c), c.active, not(c.fatalFired),
    childDo(turnEndedWith({ ...c, fatalFired: true }, false, true), "childTurnThrow"),
  }

  // The answer the child will finish with overflows one line.
  action envLongAnswer = all {
    Set("long", "longCrash").contains(scenario), alive(c), not(c.long),
    childDo({ ...c, long: true }, "envLongAnswer"),
  }

  // The child will die (OOM, kill -9, process timeout) right after it spills
  // the final text and before the result line is appended.
  action envCrashAtResult = all {
    scenario == "longCrash", alive(c), not(c.crashPlan),
    childDo({ ...c, crashPlan: true }, "envCrashAtResult"),
  }

  action childCrash = all {
    scenario == "crash", alive(c),
    childDo({ ...c, crashed: true }, "childCrash"),
  }

  action parentPollK(k: int): bool = all {
    not(settled), k >= 1, p.read + k <= c.out.length(),
    parentDo(readUpTo(p, c.out, p.read + k), "parentPoll"),
  }

  action parentPoll = all {
    p.read < c.out.length(),
    nondet k = 1.to(c.out.length() - p.read).oneOf()
    parentPollK(k),
  }

  // Read everything written so far (witnesses).
  action parentPollAll = parentPollK(c.out.length() - p.read)

  action parentDrive = all {
    not(settled),
    val np = drive(p)
    all { np != p, parentDo(np, "parentDrive") },
  }

  action userSteer(empty: bool): bool = all {
    not(settled), empty implies scenario == "empty", p.reqs.length() < MAX_STEERS,
    parentDo({ ...p, reqs: p.reqs.append({ seq: 0, empty: empty }) }, "userSteer"),
  }

  action userCancel = all {
    scenario == "cancel", not(settled), not(p.cancelReq),
    parentDo({ ...p, cancelReq: true }, "userCancel"),
  }

  // An external parent (docs/wire.md is a public contract) may send
  // `close` or `finalize` in any state, e.g. close mid-turn, then finalize.
  action externalControl(kind: str): bool = all {
    scenario == "external", not(settled), not(p.exitSeen),
    parentDo(p.send(kind, false), "external"),
  }

  // kill-after-grace once `cancel` was sent and the child is still alive
  action parentKill = all {
    not(settled), p.cancelSent, alive(c),
    childDo({ ...c, crashed: true }, "parentKill"),
  }

  // finish!: once the process is gone, drain everything, read the result's
  // spilled file and remove it, settle the run.
  action parentSettle = all {
    not(settled), not(alive(c)),
    val p1 = readUpTo(p, c.out, c.out.length())
    val unresolved = range(0, p1.reqs.length()).foldl(Set(), (s, i) =>
      if (p1.reqs[i].seq > 0 and p1.reportedSeqs.contains(p1.reqs[i].seq)) s
      else s.union(Set(i)))
    // today the path is only known from the result line; the fix has the
    // parent name the spill file (like the control/event files) and always
    // remove it
    val rm = if (FIXES.contains("667")) (if (c.spilled) 1 else 0)
             else (if (p1.gotResult and c.long and c.spilled) 1 else 0)
    all {
      p' = if (FIXES.contains("664")) { ...p1, localReported: unresolved } else p1,
      c' = c, settled' = true, removals' = removals + rm, lastAction' = "parentSettle",
      scenario' = scenario,
    }
  }

  action step = any {
    childStart, childPoll, childInject, childToolCall, childAnswer,
    childTurnError, childUnwind, childDeadline, childFatal, childTurnThrow, childCrash,
    envLongAnswer, envCrashAtResult,
    parentPoll, parentDrive, userSteer(false), userSteer(true), userCancel,
    parentKill, parentSettle,
    externalControl("close"), externalControl("finalize"),
  }

  // ---- properties ----
  pure def countKind(out: List[Ev], k: str): int =
    out.foldl(0, (n, e) => if (e.kind == k) n + 1 else n)

  pure def ackCount(out: List[Ev], s: int): int =
    out.foldl(0, (n, e) => if (e.kind == "ack" and e.ref == s) n + 1 else n)

  // No control is answered twice.
  val atMostOneAck =
    p.ctlFile.foldl(true, (ok, x) => ok and ackCount(c.out, x.seq) <= 1)

  // Every control line the child consumed was answered before it exited.
  val everyReadControlAcked =
    c.exited implies
      range(0, c.ctlRead).foldl(true, (ok, i) => ok and ackCount(c.out, p.ctlFile[i].seq) == 1)

  // An injection or drop notice naming a ref comes after that ref's ack.
  val ackBeforeEffect =
    c.out.indices().forall(i =>
      val e = c.out[i]
      val refs = if (e.kind == "injected" and e.ref > 0) Set(e.ref)
                 else if (e.kind == "dropped") e.refs.foldl(Set(), (s, r) => s.union(Set(r)))
                 else Set()
      refs.forall(r => c.out.indices().exists(j =>
        j < i and c.out[j].kind == "ack" and c.out[j].ref == r)))

  // `result` exactly once, immediately before `exit done`; none otherwise.
  val resultOnlyBeforeExitDone =
    val n = c.out.length()
    val nr = countKind(c.out, "result")
    and {
      nr <= 1,
      countKind(c.out, "exit") <= 1,
      c.exited implies and {
        c.out[n - 1].kind == "exit",
        (c.out[n - 1].status == "done") == (nr == 1 and c.out[n - 2].kind == "result"),
      },
      not(c.exited) implies nr == 0,
    }

  // Every accepted queued steer is reported exactly once: injected with its
  // ref, or listed in the one drop notice.
  val queuedSteersAccounted =
    c.exited implies c.accepted.forall(r =>
      c.out.foldl(0, (n, e) =>
        if (e.kind == "injected" and e.ref == r) n + 1
        else if (e.kind == "dropped" and e.refs.foldl(false, (f, x) => f or x == r)) n + 1
        else n) == 1)

  // Once the event file is drained, the parent's mirror equals the child's
  // state (except while a terminal child waits for its turn to unwind,
  // which emits nothing until `exit`).
  val mirrorAgreesWhenDrained =
    (not(c.crashed) and p.read == c.out.length()
     and not(TERMINAL.contains(c.st) and not(c.exited)))
      implies p.st == c.st

  // Every steer the user was told was queued ends up reported to them:
  // injected, rejected, dropped, or (fix) reported dropped at settle.
  val userSteersAccounted =
    (settled and p.exitSeen) implies
      range(0, p.reqs.length()).foldl(true, (ok, i) =>
        ok and ((p.reqs[i].seq > 0 and p.reportedSeqs.contains(p.reqs[i].seq))
                or p.localReported.contains(i)))

  // The parent never sends a steer its mirror already knows cannot apply.
  val noDoomedSteer = not(p.doomed)

  // A finalize never throws away an answer the child already finished.
  val naturalAnswerKept = not(c.replaced)

  // The spilled final-text file is removed exactly once on every path.
  val finalTextFileRemovedOnce =
    settled implies removals == (if (c.spilled) 1 else 0)

  val controlSeqIncreasing =
    p.ctlFile.indices().forall(i => i == 0 or p.ctlFile[i - 1].seq < p.ctlFile[i].seq)

  val boundedTurns = c.turns <= MAX_TURNS + MAX_STEERS + 1

  val allInvariants = and {
    atMostOneAck, everyReadControlAcked, ackBeforeEffect, resultOnlyBeforeExitDone,
    queuedSteersAccounted, mirrorAgreesWhenDrained, userSteersAccounted,
    noDoomedSteer, naturalAnswerKept, finalTextFileRemovedOnce,
    controlSeqIncreasing, boundedTurns,
  }
}

module current { import wire(FIXES = Set()).* }
module fixed { import wire(FIXES = Set("664", "665", "666", "667")).* }
module fix664 { import wire(FIXES = Set("664")).* }
module fix665 { import wire(FIXES = Set("665")).* }
module fix666 { import wire(FIXES = Set("666")).* }
module fix667 { import wire(FIXES = Set("667")).* }
