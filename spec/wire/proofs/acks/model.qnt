// Proof model: the child's per-control acks and its one `result` (#664,
// child side). Only the child's control loop is kept: three control slots
// (the task prompt, then two controls the parent may append), the read
// offset, one ack counter per slot, the run state and turn, and the last
// two lifecycle events. Steering, the parent mirror, spill files, and the
// event-file reader are the integration model's (../../model.qnt).
//
// The decide/advance rows are copied from the integration model, which
// conformance pins to packages/util/src/fen/util/wire_session.fnl; only
// rows for the controls modelled here are kept (prompt, steer, finalize,
// close, cancel; turn-done, final-turn-done). Mirrors
// extensions/adapters/presenters/rpc/init.fnl (`poll-controls!`,
// `apply-control!`, `perform!`, `turn-ended!`, `finish!`, `exit!`).
module acks {
  // "664": defer the exit a control causes to the end of the poll batch.
  const FIXES: Set[str]

  pure val TERMINAL = Set("done", "cancelled", "failed", "timed-out")
  pure val KINDS = Set("steer", "finalize", "close", "cancel")

  type Entry = { status: str, act: str, next: str }
  pure def acc(a: str, n: str): Entry = { status: "accepted", act: a, next: n }
  pure def app(n: str): Entry = { status: "applied", act: "none", next: n }
  pure val REJ: Entry = { status: "rejected", act: "none", next: "" }

  pure def decide(st: str, kind: str): Entry =
    if (TERMINAL.contains(st)) REJ
    else if (kind == "cancel") acc("abort", "cancelled")
    else if (st == "starting") REJ
    else if (st == "ready")
      if (kind == "prompt" or kind == "steer") acc("start-turn", "running")
      else if (kind == "finalize") acc("start-finalize-turn", "finalizing")
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

  // advance on a turn end: (ok, act, next)
  type Adv = { ok: bool, act: str, next: str }
  pure def advance(st: str, e: str): Adv =
    if (TERMINAL.contains(st)) { ok: true, act: "exit", next: st }
    else if (st == "running" and e == "turn-done") { ok: true, act: "none", next: "ready" }
    else if (st == "closing" and e == "turn-done") { ok: true, act: "finish", next: "done" }
    else if (st == "finalizing" and e == "turn-done")
      { ok: true, act: "start-finalize-turn", next: "finalizing" }
    else if (st == "finalizing" and e == "final-turn-done") { ok: true, act: "finish", next: "done" }
    else { ok: false, act: "none", next: "" }

  type Child = {
    st: str, active: bool, final: bool,
    a0: int, a1: int, a2: int,       // acks per control slot
    exited: bool, pend: str,         // pend: "" | "finish" | "exit"
    results: int, prev: str, last: str, exitStatus: str,
  }

  pure def emit(c: Child, k: str): Child = { ...c, prev: c.last, last: k }

  pure def exitNow(c: Child, status: str): Child =
    if (c.exited) c else { ...c.emit("exit"), exited: true, exitStatus: status }

  pure def flush(c: Child): Child =
    if (c.pend == "finish") exitNow({ ...c, pend: "", results: c.results + 1 }.emit("result"), "done")
    else if (c.pend == "exit") exitNow({ ...c, pend: "" }, c.st)
    else c

  pure def perform(c: Child, act: str): Child =
    if (act == "start-turn") { ...c, active: true, final: false }
    else if (act == "start-finalize-turn") { ...c, active: true, final: true }
    else if (act == "abort") (if (c.active) c else { ...c, pend: "exit" })
    else if (act == "exit") { ...c, pend: "exit" }
    else if (act == "finish") { ...c, pend: "finish" }
    else c   // queue, interrupt-turn (the turn unwinds later), none

  pure def ack(c: Child, i: int): Child =
    val c1 = c.emit("ack")
    if (i == 0) { ...c1, a0: c.a0 + 1 }
    else if (i == 1) { ...c1, a1: c.a1 + 1 }
    else { ...c1, a2: c.a2 + 1 }

  // apply-control!: nothing once exited; otherwise one ack, then the effect.
  pure def applyControl(c: Child, i: int, kind: str): Child =
    if (c.exited) c
    else
      val e = decide(c.st, kind)
      val c1 = ack(c, i)
      if (e.status == "rejected") c1 else perform({ ...c1, st: e.next }, e.act)

  // One control of a poll batch; `lastOfBatch` when it is the batch's last
  // line. Today each control's exit runs at once (the rest of the batch is
  // skipped, unanswered); fix 664 runs it after the batch's last ack.
  pure def applyInBatch(c: Child, i: int, kind: str, lastOfBatch: bool): Child =
    val c1 = applyControl(c, i, kind)
    if (FIXES.contains("664") and not(lastOfBatch)) c1 else flush(c1)

  pure def turnEnded(c: Child): Child =
    val c1 = { ...c, active: false }.emit("turn")
    val a = advance(c1.st, if (c.final) "final-turn-done" else "turn-done")
    val c2 = if (a.ok) perform({ ...c1, st: a.next }, a.act) else c1
    val c3 = flush(c2)
    if (not(c3.exited) and not(c3.active) and TERMINAL.contains(c3.st)) exitNow(c3, c3.st)
    else c3

  var k1: str        // kinds of the two controls after the prompt
  var k2: str
  var written: int   // controls the parent has appended (prompt included)
  var read: int      // controls the child has read
  var handled: int   // read controls handled so far (handled < read: mid-batch)
  // the child, one scalar per field (Apalache-friendly); `cur` reassembles it
  var st: str
  var active: bool
  var final: bool
  var a0: int
  var a1: int
  var a2: int
  var exited: bool
  var pend: str
  var results: int
  var prev: str
  var last: str
  var exitStatus: str

  val cur: Child = {
    st: st, active: active, final: final, a0: a0, a1: a1, a2: a2,
    exited: exited, pend: pend, results: results, prev: prev, last: last,
    exitStatus: exitStatus,
  }

  action setChild(n: Child): bool = all {
    st' = n.st, active' = n.active, final' = n.final, a0' = n.a0, a1' = n.a1,
    a2' = n.a2, exited' = n.exited, pend' = n.pend, results' = n.results,
    prev' = n.prev, last' = n.last, exitStatus' = n.exitStatus,
  }

  action initWith(x1: str, x2: str): bool = all {
    k1' = x1, k2' = x2, written' = 1, read' = 0, handled' = 0,
    setChild({ st: "starting", active: false, final: false, a0: 0, a1: 0, a2: 0,
               exited: false, pend: "", results: 0, prev: "none", last: "none",
               exitStatus: "" }),
  }

  action init = { nondet x1 = KINDS.oneOf() nondet x2 = KINDS.oneOf() initWith(x1, x2) }

  action unchangedCtl = all { k1' = k1, k2' = k2 }

  // The child's loop handles a whole poll batch before anything else it
  // does (turn ticks, the handled poll): its other actions wait for handled == read.
  action childStart = all {
    not(exited), st == "starting",
    setChild({ ...cur.emit("ready"), st: "ready" }),
    unchangedCtl, written' = written, read' = read, handled' = handled,
  }

  action parentAppend = all {
    written < 3, not(exited),
    written' = written + 1, unchangedCtl, read' = read, handled' = handled, setChild(cur),
  }

  // read-lines!: take every unread line as one batch.
  action childPoll = all {
    not(exited), st != "starting", handled == read, read < written,
    read' = written, handled' = handled, setChild(cur), unchangedCtl, written' = written,
  }

  // handle-line! on the batch's handled line (a no-op once exited).
  action childApply = all {
    handled < read,
    val kind = if (handled == 0) "prompt" else if (handled == 1) k1 else k2
    setChild(applyInBatch(cur, handled, kind, handled + 1 == read)),
    handled' = handled + 1, read' = read, unchangedCtl, written' = written,
  }

  action childTurnEnd = all {
    not(exited), active, handled == read,
    setChild(turnEnded(cur)), unchangedCtl, written' = written, read' = read,
    handled' = handled,
  }

  action step = any { childStart, parentAppend, childPoll, childApply, childTurnEnd }

  // ---- properties ----
  pure def ackOf(x: Child, i: int): int = if (i == 0) x.a0 else if (i == 1) x.a1 else x.a2

  val atMostOneAck = a0 <= 1 and a1 <= 1 and a2 <= 1

  val everyReadControlAcked =
    exited implies Set(0, 1, 2).forall(i => i < handled implies ackOf(cur, i) == 1)

  val noAckUnread = Set(0, 1, 2).forall(i => i >= handled implies ackOf(cur, i) == 0)

  val resultOnlyBeforeExitDone = and {
    results <= 1,
    not(exited) implies results == 0,
    exited implies (last == "exit"
                    and (exitStatus == "done") == (results == 1 and prev == "result")),
  }

  val allInvariants = and {
    atMostOneAck, everyReadControlAcked, noAckUnread, resultOnlyBeforeExitDone,
  }

  // ---- inductive strengthening ----
  pure val STATES = Set("starting", "ready", "running", "closing", "finalizing",
                        "done", "cancelled", "failed", "timed-out")
  pure val EVENTS = Set("none", "ready", "ack", "turn", "result", "exit")

  // Types and ranges first: Apalache's induction step starts anywhere.
  val typeOk = and {
    k1.in(KINDS), k2.in(KINDS), written.in(1.to(3)), read.in(0.to(3)), handled.in(0.to(3)),
    st.in(STATES), active.in(Set(true, false)), final.in(Set(true, false)),
    a0.in(0.to(1)), a1.in(0.to(1)), a2.in(0.to(1)), exited.in(Set(true, false)),
    pend.in(Set("", "finish", "exit")), results.in(0.to(1)), prev.in(EVENTS),
    last.in(EVENTS), exitStatus.in(Set("", "done", "cancelled", "failed", "timed-out")),
  }

  val strengthening = and {
    handled <= read, read <= written,
    // an exit waits for the end of the batch
    pend != "" implies handled < read,
    exited implies handled == read,
    // the child acks every line it handled, and nothing else
    Set(0, 1, 2).forall(i => i < handled implies ackOf(cur, i) == 1),
    noAckUnread,
    st == "starting" implies (read == 0 and not(active) and last == "none"),
    exited implies not(active),
    exited implies pend == "",
    pend == "finish" implies st == "done",
    (st == "done" and not(exited)) implies pend == "finish",
    prev != "exit",
    pend != "" implies (not(active) and handled >= 1),
    pend == "exit" implies TERMINAL.contains(st),
    prev == "result" implies exited,
    (last == "exit") == exited,
    // a turn runs exactly in the in-turn states (and while a terminal run unwinds)
    Set("running", "closing", "finalizing").contains(st) implies active,
    Set("starting", "ready").contains(st) implies not(active),
    final implies not(Set("starting", "ready", "running", "closing").contains(st)),
    exited == (exitStatus != ""),
    exited implies exitStatus == st,
    // a terminal child is unwinding its turn or has exited
    (TERMINAL.contains(st) and not(exited) and pend == "") implies active,
    // `result` is emitted only by finish, right before `exit done`
    results == (if (exited and exitStatus == "done") 1 else 0),
    (exited and exitStatus == "done") implies prev == "result",
    exited implies last == "exit",
    last != "result",
  }

  val fixedInductive = and { typeOk, strengthening, allInvariants }
}

module current { import acks(FIXES = Set("664")).* }
module fixed { import acks(FIXES = Set("664")).* }
