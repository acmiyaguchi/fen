// Proof model: RPC ref accounting. Every line control (prompt, steer,
// follow-up) the child accepts gets exactly one terminal notice on the wire:
// `turn-started` naming it (started), a `steering-injected` or
// `follow-up-injected` naming it (taken), or an `info` whose `refs` name it
// (refused, released, cleared, or a start that failed). A control rejected at
// ack gets none of those, only the rejection.
//
// The child's control handling composes with the session holder: every
// mailbox step is a pure def of `holderAbstract`
// (spec/core/tasks/proofs/holder/model.qnt), called, not re-implemented. A
// wire ref r is admitted as holder seq r (a slot): the holder only needs seqs
// fresh and increasing, so a ref the holder never sees just leaves its slot
// unused, and the tag the code carries (the wire seq) is the identity here.
// The last slot (FIN) is the forced finalize turn's own line, which has no
// ref. As in the code, the rpc child keeps no ref bookkeeping of its own: it
// forwards what the mailbox hands back. So the accounting reduces to: the child emits one
// notice exactly when the holder records one disposition (or, for a line
// the holder never admitted, when the child refuses or fails it itself).
//
// The decide/advance rows are copied from the integration model
// (../../model.qnt), which conformance pins to
// packages/util/src/fen/util/wire_session.fnl; the follow-up control and the
// fatal event are added. Batching, acks, and the parent mirror are the other
// proofs' (../acks, ../../model.qnt): here a control is acked and applied in
// one step. Mirrors extensions/adapters/presenters/rpc/init.fnl
// (`apply-control!`, `queue!`, `start-turn!`, `drop-queued!`, `turn-ended!`,
// `adopt-turn!`, `adopt-pending!`, `forward!`), with the interactive
// runtime's tick (resume, release, `start-queued!`) folded into the same
// step as the presenter's tick, as both run in one loop iteration.
module refs {
  import holderAbstract.* from "../../../core/tasks/proofs/holder/model"

  // Line controls the parent may send (wire refs 0..2): one seq is kept
  // for the forced finalize turn's own line (tag absent).
  pure val REFS = 0.to(MAX_SEQ - 1)
  pure val MAX_LINES = MAX_SEQ - 1
  pure val FIN = MAX_SEQ - 1
  pure val MAX_H = 4
  pure val NONE = -1
  pure val TERMINAL_STATES = Set("done", "cancelled", "failed", "timed-out")
  pure val WIRE_STATES = Set("starting", "ready", "running", "closing", "finalizing",
                             "done", "cancelled", "failed", "timed-out")
  pure val LINE_KINDS = Set("prompt", "steer", "follow-up")
  pure val OTHER_KINDS = Set("finalize", "close", "cancel")
  // The child's own view of the turn: none, a turn it started or adopted,
  // a start line waiting behind an exclusive job, or an adopted exclusive job.
  pure val ACTIVES = Set("none", "turn", "pending", "excl")

  // ---- wire_session (copied rows) ----
  type Entry = { status: str, act: str, next: str }
  pure def accept(a: str, nx: str): Entry = { status: "accepted", act: a, next: nx }
  pure def applied(nx: str): Entry = { status: "applied", act: "none", next: nx }
  pure val REJECT: Entry = { status: "rejected", act: "none", next: "" }

  pure def decide(st: str, kind: str): Entry =
    if (TERMINAL_STATES.contains(st)) REJECT
    else if (kind == "cancel") accept("abort", "cancelled")
    else if (st == "starting") REJECT
    else if (st == "ready")
      if (LINE_KINDS.contains(kind)) accept("start-turn", "running")
      else if (kind == "finalize" or kind == "close") accept("finish", "done")
      else REJECT
    else if (st == "running")
      if (kind == "steer") accept("queue-steering", "running")
      else if (kind == "follow-up") accept("queue-follow-up", "running")
      else if (kind == "finalize") accept("interrupt-turn", "finalizing")
      else if (kind == "close") accept("none", "closing")
      else REJECT
    else if (st == "closing")
      if (kind == "finalize") accept("interrupt-turn", "finalizing")
      else if (kind == "close") applied("closing")
      else REJECT
    else if (st == "finalizing")
      if (kind == "finalize" or kind == "close") applied("finalizing")
      else REJECT
    else REJECT

  type Adv = { ok: bool, act: str, next: str }
  pure def advance(st: str, e: str): Adv =
    if (TERMINAL_STATES.contains(st))
      if (e == "fatal") { ok: true, act: "abort", next: st }
      else { ok: true, act: "exit", next: st }
    else if (e == "fatal") { ok: true, act: "abort", next: "failed" }
    else if (st == "starting" and e == "started") { ok: true, act: "none", next: "ready" }
    else if (st == "running" and e == "turn-done") { ok: true, act: "none", next: "ready" }
    else if (st == "closing" and e == "turn-done") { ok: true, act: "finish", next: "done" }
    else if (st == "finalizing" and e == "turn-done")
      { ok: true, act: "start-finalize-turn", next: "finalizing" }
    else if (st == "finalizing" and e == "final-turn-done") { ok: true, act: "finish", next: "done" }
    else { ok: false, act: "none", next: "" }

  // ---- the child plus its mailbox ----
  type W = {
    h: Session,            // the session holder (holderAbstract); seq = ref slot
    st: str,               // wire_session state
    active: str,           // ACTIVES
    final: bool,           // the active (or pending) turn is the forced finalize turn
    cn: int,               // ch.active.n: the turn number a steer is offered for
    exited: bool,
    nextRef: int,          // line controls sent so far
    acked: int -> str,     // ref -> ack status ("" unsent)
    notes: int -> int,     // ref -> terminal notices on the wire
    asSteer: int -> bool,  // ref -> accepted as queue-steering
  }

  pure def queuedOf(a: Session): Set[int] = a.steer.union(a.followUp)

  // forward!: a notice for every listed seq that carries a ref (not FIN).
  pure def noteSeqs(w: W, qs: Set[int]): W =
    { ...w, notes: REFS.mapBy(r => w.notes.get(r) +
                                   (if (r != FIN and qs.contains(r)) 1 else 0)) }

  // An `info` naming ref r directly (a line the mailbox never admitted).
  pure def noteRef(w: W, r: int): W =
    if (r >= 0) { ...w, notes: w.notes.set(r, w.notes.get(r) + 1) } else w

  // drop-queued!: clear both queues; one `info` names every cleared ref.
  pure def dropQueued(w: W): W =
    noteSeqs({ ...w, h: clearFollowUp(clearSteer(w.h)) }, queuedOf(w.h))

  pure def exitW(w: W): W =
    if (w.exited) w else { ...dropQueued(w), exited: true }

  // tasks.offer! for ref r (tag r); a refused line is reported at once.
  // r is the slot (FIN for the forced finalize line).
  pure def admit(w: W, r: int, t: int, f: bool): W =
    val b = offer(w.h, r, t, f)
    val w1 = { ...w, h: b }
    if (b.why.get(r) == "refused") noteRef(w1, r) else w1

  // ---- apply-control!, one pure function per (control, state class) ----
  // Each is the `decide` row it implements, specialized, with a flat result:
  // the step never dispatches on the table, so each induction obligation
  // builds only its own effect. The guards (below) select the class by
  // `decide`, so the rows still come from the copied table.

  // The ack for line ref r = nextRef.
  pure def ackLine(w: W, status: str): W =
    { ...w, nextRef: w.nextRef + 1, acked: w.acked.set(w.nextRef, status) }

  // Any line control rejected at ack (state, or empty steer/follow-up text).
  pure def lineRejectW(w: W): W = ackLine(w, "rejected")

  // ready + prompt/steer/follow-up: start-turn! (offer-start!). Idle: the line
  // starts at once and turn-started names it. Behind an exclusive job: it
  // waits with a start request.
  pure def lineStartW(w: W): W =
    val r = w.nextRef
    val w0 = ackLine(w, "accepted")
    val b0 = offer(w.h, r, NONE, false)
    if (w.h.kind == "none")
      val b = startTurn(b0)
      noteRef({ ...w0, h: b, st: "running", active: "turn", cn: b.n }, r)
    else { ...w0, h: b0, st: "running", active: "pending" }

  // ready + empty prompt: accepted, but the mailbox rejects the empty line, so
  // the start fails: the ref is reported, then fatal! (abort, no turn: exit).
  // In ready no turn holds, so only follow-ups can be queued: exit's
  // drop-queued! clears those, in the same flat step.
  pure def promptFailW(w: W): W =
    val r = w.nextRef
    val failed = Set(r)
    { ...ackLine(w, "accepted"), st: "failed", exited: true,
      h: clearFollowUp(w.h),
      notes: REFS.mapBy(q => w.notes.get(q) +
                             (if (failed.contains(q) or w.h.followUp.contains(q)) 1 else 0)) }

  // running + steer: queue! :steering, only to the child's own turn by number.
  pure def steerRunW(w: W): W =
    val r = w.nextRef
    val w0 = { ...ackLine(w, "accepted"), asSteer: w.asSteer.set(r, true) }
    if (w.active == "turn")
      val b = offer(w.h, r, w.cn, false)
      val w1 = { ...w0, h: b }
      if (b.why.get(r) == "refused") noteRef(w1, r) else w1
    else noteRef(w0, r)

  // running + follow-up: queue! :follow-up.
  pure def followRunW(w: W): W =
    { ...ackLine(w, "accepted"), h: offer(w.h, w.nextRef, NONE, true) }

  // ready + finalize/close: finish (drop-queued!, result, exit done).
  pure def finishReadyW(w: W): W = exitW({ ...w, st: "done" })

  // running/closing + finalize: drop-queued!, then interrupt-turn!. A start
  // line still waiting behind an exclusive job was just dropped, so its turn
  // will never start: the run is as in ready and finishes.
  pure def finalizeBusyW(w: W): W =
    val w1 = { ...dropQueued(w), st: "finalizing" }
    if (w.active == "pending") exitW({ ...w1, active: "none", st: "done" })
    else w1

  // running + close: closing.
  pure def closeRunW(w: W): W = { ...w, st: "closing" }

  // cancel in any live state: abort; with no turn, exit at once.
  pure def cancelW(w: W): W =
    if (w.active == "none") exitW({ ...w, st: "cancelled" }) else { ...w, st: "cancelled" }

  // The forced finalize turn, started from a turn end: the holder was just
  // released, so its line (slot FIN, no ref) starts at once.
  pure def startFinalW(w: W): W =
    val b = startTurn(offer(w.h, FIN, NONE, false))
    { ...w, h: b, active: "turn", final: true, cn: b.n }

  // turn-ended!: the turn (or adopted job) is gone; advance, and never idle
  // in a terminal state. The `advance` rows for turn-done/final-turn-done,
  // one branch per state, so each branch builds only its own effect.
  pure def turnEndedW(w: W): W =
    val w1 = { ...w, active: "none" }
    if (TERMINAL_STATES.contains(w.st)) exitW(w1)
    else if (w.st == "running") { ...w1, st: "ready" }
    else if (w.st == "closing") exitW({ ...w1, st: "done" })
    else if (w.st == "finalizing" and w.final) exitW({ ...w1, st: "done" })
    else if (w.st == "finalizing") startFinalW(w1)
    else w1

  // The turn body exits: release hands back its unread steer lines
  // (steering-returned -> one `info`), then the presenter sees the turn end.
  pure def bodyExitW(w: W): W =
    turnEndedW(noteSeqs({ ...w, h: release(w.h) }, w.h.steer))

  // The idle tick starts the pending turn (next-job!); the presenter adopts
  // it in the same loop iteration, naming the started line's tag.
  pure def tickStartW(w: W): W =
    val b = startTurn(w.h)
    val started = w.h.followUp.exclude(b.followUp)
    if (w.active == "pending") noteSeqs({ ...w, h: b, active: "turn", cn: b.n }, started)
    else noteSeqs({ ...w, h: b, active: "turn", cn: b.n, st: "running" }, started)

  // The agent drains at a boundary; each injected line names its tag.
  pure def takeW(w: W, which: str): W =
    val b = if (which == "steer") takeSteer(w.h) else takeFollowUp(w.h)
    noteSeqs({ ...w, h: b }, queuedOf(w.h).exclude(queuedOf(b)))

  pure def exStartW(w: W, adopt: bool): W =
    val b = startExclusive(requestExclusive(w.h))
    if (adopt) { ...w, h: b, active: "excl", st: "running" } else { ...w, h: b }

  pure def exEndW(w: W): W =
    val w1 = noteSeqs({ ...w, h: release(w.h) }, w.h.steer)
    if (w.active == "excl") turnEndedW(w1) else w1

  pure def initW(sm: str, fm: str): W = {
    h: { ...sessionInit, steerMode: sm, followMode: fm },
    st: "starting", active: "none", final: false, cn: 0, exited: false,
    nextRef: 0,
    acked: REFS.mapBy(_r => ""), notes: REFS.mapBy(_r => 0),
    asSteer: REFS.mapBy(_r => false),
  }

  // ---- state ----
  // One variable per field (Apalache's induction needs each typed by `.in`);
  // `w` reassembles them.
  var hKind: str
  var hN: int
  var hHid: int
  var hSteer: Set[int]
  var hFollowUp: Set[int]
  var hStart: bool
  var hFirstUp: int
  var hExReq: bool
  var hCancel: bool
  var hSteerMode: str
  var hFollowMode: str
  var hWhy: int -> str
  var hWhyN: int -> int
  var st: str
  var active: str
  var final: bool
  var cn: int
  var exited: bool
  var nextRef: int
  var acked: int -> str
  var notes: int -> int
  var asSteer: int -> bool

  val w: W = {
    h: { kind: hKind, n: hN, hid: hHid, steer: hSteer, followUp: hFollowUp, start: hStart,
         firstUp: hFirstUp, exReq: hExReq, cancel: hCancel, steerMode: hSteerMode,
         followMode: hFollowMode, why: hWhy, whyN: hWhyN },
    st: st, active: active, final: final, cn: cn, exited: exited,
    nextRef: nextRef, acked: acked, notes: notes, asSteer: asSteer,
  }

  action setW(x: W): bool = all {
    hKind' = x.h.kind, hN' = x.h.n, hHid' = x.h.hid, hSteer' = x.h.steer,
    hFollowUp' = x.h.followUp, hStart' = x.h.start, hFirstUp' = x.h.firstUp,
    hExReq' = x.h.exReq, hCancel' = x.h.cancel, hSteerMode' = x.h.steerMode,
    hFollowMode' = x.h.followMode, hWhy' = x.h.why, hWhyN' = x.h.whyN,
    st' = x.st, active' = x.active, final' = x.final, cn' = x.cn,
    exited' = x.exited, nextRef' = x.nextRef, acked' = x.acked,
    notes' = x.notes, asSteer' = x.asSteer,
  }

  action initWith(sm: str, fm: str): bool = setW(initW(sm, fm))
  action init = { nondet sm = MODES.oneOf() nondet fm = MODES.oneOf() initWith(sm, fm) }
  // Conformance replay starts where the real child's loop starts: after `ready`.
  action initReady = { nondet sm = MODES.oneOf() nondet fm = MODES.oneOf()
                       setW({ ...initW(sm, fm), st: "ready" }) }

  action childStart = all {
    not(w.exited), w.st == "starting",
    setW({ ...w, st: "ready" }),
  }

  // A line control (ref = nextRef), one action per class; `decide` picks it.
  pure def lineEntry(st: str, kind: str, empty: bool): Entry =
    if (empty and (kind == "steer" or kind == "follow-up")) REJECT else decide(st, kind)

  action lineReject(kind: str, empty: bool): bool = all {
    not(w.exited), w.nextRef < MAX_LINES,
    lineEntry(w.st, kind, empty).status == "rejected",
    setW(lineRejectW(w)),
  }
  action lineStart(kind: str): bool = all {
    not(w.exited), w.nextRef < MAX_LINES,
    decide(w.st, kind).act == "start-turn",
    setW(lineStartW(w)),
  }
  action promptFail = all {
    not(w.exited), w.nextRef < MAX_LINES,
    decide(w.st, "prompt").act == "start-turn",
    setW(promptFailW(w)),
  }
  action steerRun = all {
    not(w.exited), w.nextRef < MAX_LINES,
    decide(w.st, "steer").act == "queue-steering",
    setW(steerRunW(w)),
  }
  action followRun = all {
    not(w.exited), w.nextRef < MAX_LINES,
    decide(w.st, "follow-up").act == "queue-follow-up",
    setW(followRunW(w)),
  }

  action parentLine(kind: str, empty: bool): bool =
    if (lineEntry(w.st, kind, empty).status == "rejected") lineReject(kind, empty)
    else if (kind == "prompt" and empty) promptFail
    else if (kind == "steer" and w.st == "running") steerRun
    else if (kind == "follow-up" and w.st == "running") followRun
    else lineStart(kind)

  // finalize/close/cancel: no ref. Rejected or applied rows change nothing.
  action finishReady(kind: str): bool = all {
    not(w.exited), decide(w.st, kind).act == "finish",
    setW(finishReadyW(w)),
  }
  action finalizeBusy = all {
    not(w.exited), decide(w.st, "finalize").act == "interrupt-turn",
    setW(finalizeBusyW(w)),
  }
  action closeRun = all {
    not(w.exited), decide(w.st, "close").act == "none", decide(w.st, "close").status == "accepted",
    setW(closeRunW(w)),
  }
  action cancel = all {
    not(w.exited), decide(w.st, "cancel").act == "abort",
    setW(cancelW(w)),
  }

  action parentCtl(kind: str): bool =
    if (kind == "cancel") cancel
    else if (decide(w.st, kind).act == "finish") finishReady(kind)
    else if (kind == "finalize") finalizeBusy
    else closeRun

  action bodyExit = all {
    not(w.exited), w.h.kind == "turn",
    setW(bodyExitW(w)),
  }

  action takeSteerLines = all {
    not(w.exited), w.h.kind == "turn", w.h.steer != Set(),
    setW(takeW(w, "steer")),
  }

  action takeFollowUps = all {
    not(w.exited), w.h.kind == "turn", w.h.steer == Set(), w.h.followUp != Set(),
    setW(takeW(w, "followUp")),
  }

  action tickStart = all {
    not(w.exited), canStartTurn(w.h), w.h.n < MAX_SEQ,
    // a start the child did not ask for is adopted only in ready
    w.active == "pending" or (w.active == "none" and w.st == "ready"),
    setW(tickStartW(w)),
  }

  // An exclusive job (/reload, compaction) the scheduler starts at once:
  // idle, no turn start pending. Adopted (state.turn set) only in ready.
  action exStart(adopt: bool): bool = all {
    not(w.exited), w.h.kind == "none", not(canStartTurn(w.h)), w.h.hid < MAX_H,
    not(adopt) or (w.active == "none" and w.st == "ready"),
    setW(exStartW(w, adopt)),
  }

  action exEnd = all {
    not(w.exited), w.h.kind == "exclusive",
    setW(exEndW(w)),
  }

  action step = {
    nondet lk = LINE_KINDS.oneOf()
    nondet ok = OTHER_KINDS.oneOf()
    nondet empty = Bool.oneOf()
    nondet adopt = Bool.oneOf()
    any {
      childStart,
      parentLine(lk, empty),
      parentCtl(ok),
      bodyExit,
      takeSteerLines,
      takeFollowUps,
      tickStart,
      exStart(adopt),
      exEnd,
    }
  }

  // The step, split into one move per induction obligation, so each stays
  // small (`step` is exactly their union, so together they prove it).
  action stepLineReject = {
    nondet k = LINE_KINDS.oneOf()
    nondet e = Bool.oneOf()
    lineReject(k, e)
  }
  action stepLineStart = { nondet k = LINE_KINDS.oneOf() lineStart(k) }
  action stepPromptFail = promptFail
  action stepSteer = steerRun
  action stepFollowUp = followRun
  action stepFinish = { nondet k = Set("finalize", "close").oneOf() finishReady(k) }
  action stepFinalize = finalizeBusy
  action stepClose = closeRun
  action stepCancel = cancel
  action stepBodyExit = bodyExit
  action stepTake = any { takeSteerLines, takeFollowUps }
  action stepSched = { nondet adopt = Bool.oneOf() any { childStart, tickStart, exStart(adopt), exEnd } }

  // ---- properties ----
  pure def acceptedLine(x: W, r: int): bool =
    x.acked.get(r) == "accepted"

  // No ref gets two terminal notices.
  val atMostOneNotice = REFS.forall(r => w.notes.get(r) <= 1)

  // A ref rejected at ack (or never sent) gets no notice.
  val rejectedNoNotice = REFS.forall(r => not(acceptedLine(w, r)) implies w.notes.get(r) == 0)

  // The child reports a ref exactly when its line leaves the mailbox (taken,
  // started, released, refused, cleared), or at once when the mailbox never
  // admitted it: an accepted line still queued has no notice, any other has one.
  val noticeIffDisposed = REFS.forall(r => (r != FIN and acceptedLine(w, r)) implies
    w.notes.get(r) == (if (queuedOf(w.h).contains(r)) 0 else 1))

  // Once the run exits, or the session is idle with empty queues, every
  // accepted line has its one notice.
  val settledAccounted =
    (w.exited or (w.h.kind == "none" and queuedOf(w.h) == Set() and w.active == "none"))
      implies REFS.forall(r => acceptedLine(w, r) implies w.notes.get(r) == 1)

  // A steer is for the running turn: it never starts a turn of its own.
  val steerNeverStarts = REFS.forall(r =>
    w.asSteer.get(r) implies (w.h.why.get(r) != "started" and not(w.h.followUp.contains(r))))

  // A waiting start line is still queued with its start request, so the
  // scheduler will start it (no run left waiting for a turn that never comes).
  val pendingWillStart = w.active == "pending" implies
    (w.h.kind != "turn" and w.h.start and w.h.followUp != Set())

  val allInvariants = and {
    atMostOneNotice, rejectedNoNotice, noticeIffDisposed, settledAccounted,
    steerNeverStarts, pendingWillStart,
  }

  // ---- inductive strengthening ----
  val typeOk = and {
    hKind.in(KINDS), hN.in(0.to(MAX_SEQ)), hHid.in(0.to(MAX_H + MAX_SEQ)),
    hSteer.in(powerset(SEQS)), hFollowUp.in(powerset(SEQS)),
    hStart.in(Bool), hFirstUp.in(Set(NONE).union(SEQS)), hExReq.in(Bool),
    hCancel.in(Bool), hSteerMode.in(MODES), hFollowMode.in(MODES),
    hWhy.in(setOfMaps(SEQS, WHYS)), hWhyN.in(setOfMaps(SEQS, 0.to(MAX_SEQ))),
    st.in(WIRE_STATES), active.in(ACTIVES),
    final.in(Bool), cn.in(0.to(MAX_SEQ)), exited.in(Bool), nextRef.in(0.to(MAX_LINES)),
    acked.in(setOfMaps(REFS, Set("", "accepted", "rejected"))),
    notes.in(setOfMaps(REFS, 0.to(2))),
    asSteer.in(setOfMaps(REFS, Bool)),
  }

  val strengthening = and {
    sessionInv(w.h),
    not(w.h.cancel), not(w.h.exReq),
    w.h.start == (w.h.firstUp >= 0),
    w.h.firstUp >= 0 implies w.h.followUp.contains(w.h.firstUp),
    w.h.hid <= MAX_H + w.h.n,
    // every turn number was opened by exactly one started line
    SEQS.filter(q => w.h.why.get(q) == "started").size() == w.h.n,
    // a steer is offered for the child's own running turn: never refused
    SEQS.forall(q => w.h.why.get(q) != "refused"),
    // a queued or disposed slot is an accepted line, or FIN
    SEQS.forall(q => (queuedOf(w.h).contains(q) or w.h.why.get(q) != "") implies
      (q == FIN or acceptedLine(w, q))),
    SEQS.forall(q => not(queuedOf(w.h).contains(q) and w.h.why.get(q) != "")),
    // unsent refs are blank; sent ones were accepted or rejected
    REFS.forall(r => r != FIN implies
      (if (r >= w.nextRef)
         and { w.acked.get(r) == "", w.notes.get(r) == 0, not(w.asSteer.get(r)),
               not(queuedOf(w.h).contains(r)), w.h.why.get(r) == "" }
       else w.acked.get(r) != "")),
    w.acked.get(FIN) == "", w.notes.get(FIN) == 0, not(w.asSteer.get(FIN)),
    REFS.forall(r => w.asSteer.get(r) implies acceptedLine(w, r)),
    REFS.forall(r => w.asSteer.get(r) implies not(w.h.followUp.contains(r))),
    SEQS.forall(q => w.h.steer.contains(q) implies w.asSteer.get(q)),
    // FIFO: queued slots are below nextRef (FIN aside), so offers stay fresh
    SEQS.forall(q => (queuedOf(w.h).contains(q) and q != FIN) implies q < w.nextRef),
    // the forced finalize line is used once, only under finalizing
    (queuedOf(w.h).contains(FIN) or w.h.why.get(FIN) != "") implies w.final,
    not(queuedOf(w.h).contains(FIN)),
    // the child's turn is the holder's turn
    (w.h.kind == "turn") == (w.active == "turn"),
    w.active == "turn" implies w.cn == w.h.n,
    w.active == "excl" implies w.h.kind == "exclusive",
    w.active == "excl" implies not(w.final),
    w.h.start implies w.active == "pending",
    // run state vs the child's turn
    w.st == "starting" implies and { w.active == "none", REFS.forall(r => not(acceptedLine(w, r))), w.h.kind != "turn",
                                     w.h.followUp == Set() },
    w.st == "ready" implies (w.active == "none" and not(w.h.start) and not(w.final)),
    Set("running", "closing", "finalizing").contains(w.st) implies w.active != "none",
    w.final implies (w.st == "finalizing" or TERMINAL_STATES.contains(w.st)),
    w.final implies (w.active != "none" or w.exited),
    not(w.final) implies w.h.why.get(FIN) == "",
    // finalize dropped every queued line; only the forced turn's own may wait
    w.st == "finalizing" implies queuedOf(w.h) == Set(),
    w.exited implies and { TERMINAL_STATES.contains(w.st), w.active == "none",
                           queuedOf(w.h) == Set(), w.h.kind != "turn" },
    (TERMINAL_STATES.contains(w.st) and not(w.exited)) implies w.active != "none",
    w.active == "pending" implies w.h.kind != "turn",
    // the forced turn is the one FIN started; a waiting line is a real ref
    (w.active == "turn" and w.final) implies (w.h.why.get(FIN) == "started" and w.h.whyN.get(FIN) == w.h.n),
    w.active == "pending" implies not(w.final),
    w.h.firstUp != FIN,
  }

  val inductive = and { typeOk, strengthening, allInvariants }
}
