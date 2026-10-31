// Design-first model of attachable fen: the serve sidecar and wire event
// stream (#394, #396), remote input / steering / cancel (#397), and the async
// UI contract that replaces blocking ui.select with
// select-requested / select-resolved (#398).
//
// Nothing here is built yet. The model encodes the designs as the issues
// state them, plus the existing code they say they reuse:
//
//   #396  attach = replay the session JSONL in yielding chunks, then follow
//         live bus events; reuse extensions/adapters/presenters/web/server.fnl
//   #397  inputs go into the existing steering/follow-up queues
//         (extensions/behaviors/kernel/steering/service.fnl, untagged strings);
//         cancel uses the TUI path (interactive.fnl request-cancel: sets
//         state.cancel-requested? on whatever turn is running)
//   #398  agent emits select-requested{id, choices}, parks; any client
//         answers; first writer wins; late answers ignored; winner broadcast
//
// One process, one agent loop. Client 0 is the in-process presenter (TUI);
// it sees bus events synchronously. Clients 1 and 2 are remote serve clients
// that see events only when the stream delivers them, so their view lags.
//
// Each const selects one design choice; the module instances at the bottom
// pick the issue designs as written and the proposed protocol.
module serve {
  // true: an answer names its request id and resolves only that request
  // (#398). false: today's web /select, whose POST body is a bare index that
  // finish-select! applies to whatever select is active.
  const ANSWER_BY_ID: bool
  // A late or duplicate answer gets a visible rejection to its sender
  // (docs/wire.md: every control gets exactly one control-ack). #398 says
  // "late answers are ignored".
  const ACK_ANSWERS: bool
  // Ending or cancelling a turn resolves its pending request (#398 silent).
  const END_RESOLVES: bool
  // Pending requests carry a deadline (#398 silent).
  const TIMEOUTS: bool
  // Steer / cancel / prompt carry the turn id the sender saw and are
  // rejected when it is not the running turn (#397: plain queue + TUI cancel).
  const TARGETED: bool
  // "jsonlGap": #396 replay of the session JSONL snapshot, then live from the
  //   end of replay (events during the yielding replay are skipped).
  // "jsonlDup": live from attach while the yielding replay reads the growing
  //   JSONL (events during replay arrive twice).
  // "ring":     proposed: every bus event has a seq; resume(from) replays a
  //   bounded ring, else an explicit snapshot reset (messages + turn state +
  //   pending requests) at a recorded seq, then live by cursor.
  const REPLAY: str
  // An idle-only command whose select resolves re-checks idle before acting.
  const RECHECK: bool
  // Choice-list refreshes are broadcast (select-updated) with a version and
  // answers carry the version they were made against.
  const VERSIONED: bool
  // An in-process presenter that can answer requests is present.
  const LOCAL: bool
  // Remote input lines starting with "/" dispatch commands (today's web
  // /input -> drain-inputs! -> on-submit -> command-registry.dispatch).
  const REMOTE_SLASH: bool
  // /reload resolves (cancels) idle-scoped pending requests.
  const RELOAD_RESOLVES: bool

  pure val CLIENTS = Set(0, 1, 2)
  pure val REMOTES = Set(1, 2)
  pure val MAX_TURNS = 3
  pure val MAX_REQS = 3
  pure val MAX_LOG = 10
  pure val RING = 3
  pure val MAX_VER = 1

  // Bus event. kind: "turn" (turn-started), "end" (turn complete/cancelled),
  // "msg" (a message appended: persisted in the session JSONL), "req"
  // (select-requested), "res" (select-resolved), "upd" (select-updated).
  type Ev = { kind: str, turn: int, req: int, ver: int }

  // turn = 0: idle-scoped request (a slash command's picker, e.g. /resume,
  // /model); turn > 0: issued from inside that turn (tool, permission).
  // status: pending | answered | timeout | ended | cancelled | aborted
  // deadline: the request was issued with a deadline (TIMEOUTS).
  type Req = { turn: int, gen: int, status: str, wins: int, ver: int, deadline: bool }

  type Cl = {
    conn: bool, attaching: bool,
    cursor: int,              // live: number of log entries consumed
    replayPos: int, replayEnd: int,   // JSONL replay scan (-1 end = growing)
    got: List[int],           // seqs delivered this connection (seq = index + 1)
    base: int,                // seq the client already had when it (re)attached
    lastMax: int,             // last consumed seq, kept across disconnect
    seenTurn: int,            // running turn as the client believes (0 = idle)
    known: Set[int],          // requests the client believes pending
    ever: Set[int],           // request ids the client has seen
    verSeen: int -> int,      // choice-list version shown per request
  }

  type Steer = { seen: int, src: int }
  type CancelRec = { seen: int, hit: int }
  type SteerRec = { seen: int, into: int }
  type Applied = { aimed: int, target: int, inScope: bool, fresh: bool, verOk: bool }

  type S = {
    gen: int, turnNo: int, running: bool, parkedOn: int,
    reqs: int -> Req, nextReq: int,
    log: List[Ev], cl: int -> Cl, queue: List[Steer],
    // ghost history
    cancels: List[CancelRec], steers: List[SteerRec], applied: List[Applied],
    unacked: int, remoteCmds: int,
  }

  pure val freshCl: Cl = {
    conn: false, attaching: false, cursor: 0, replayPos: 0, replayEnd: 0,
    got: [], base: 0, lastMax: 0, seenTurn: 0,
    known: Set(), ever: Set(), verSeen: Map(),
  }

  pure def ev(k: str, t: int, r: int, v: int): Ev = { kind: k, turn: t, req: r, ver: v }
  pure def persisted(e: Ev): bool = e.kind == "msg"
  pure def verOf(m: int -> int, k: int): int = if (m.keys().contains(k)) m.get(k) else 0
  pure def maxOf(xs: List[int]): int = xs.foldl(0, (a, x) => if (x > a) x else a)

  // Fold one delivered event into a client's view.
  pure def view(c: Cl, e: Ev): Cl =
    if (e.kind == "turn") { ...c, seenTurn: e.turn }
    else if (e.kind == "end") { ...c, seenTurn: 0 }
    else if (e.kind == "req")
      { ...c, known: c.known.union(Set(e.req)), ever: c.ever.union(Set(e.req)),
              verSeen: c.verSeen.put(e.req, e.ver) }
    else if (e.kind == "res") { ...c, known: c.known.exclude(Set(e.req)) }
    else if (e.kind == "upd") { ...c, verSeen: c.verSeen.put(e.req, e.ver) }
    else c

  pure def deliverOne(c: Cl, log: List[Ev]): Cl =
    { ...view(c, log[c.cursor]), cursor: c.cursor + 1, got: c.got.append(c.cursor + 1) }

  // The TUI is an in-process api.on :* subscriber: it sees every event at once.
  pure def syncLocal(st: S): S =
    if (not(LOCAL)) st
    else
      val c0 = st.cl.get(0)
      { ...st, cl: st.cl.set(0, st.log.indices().filter(i => i >= c0.cursor)
                                   .fold(c0, (c, _i) => deliverOne(c, st.log))) }

  pure def emit(st: S, e: Ev): S = { ...st, log: st.log.append(e) }

  pure def pendingIds(st: S): Set[int] =
    st.reqs.keys().filter(i => st.reqs.get(i).status == "pending")

  pure def setStatus(st: S, i: int, status: str): S =
    { ...st, reqs: st.reqs.set(i, { ...st.reqs.get(i), status: status }) }

  // Resolve every pending request matching `which` with `status`, broadcasting.
  pure def resolveWhere(st: S, ids: Set[int], status: str): S =
    ids.fold(st, (acc, i) => acc.setStatus(i, status).emit(ev("res", 0, i, 0)))

  // A turn finishes (naturally or cancelled).
  pure def endTurn(st: S): S =
    val t = st.turnNo
    val base = { ...st, running: false, parkedOn: -1 }
               .emit(ev("msg", t, -1, 0)).emit(ev("end", t, -1, 0))
    val ownPending = pendingIds(base).filter(i => base.reqs.get(i).turn == t)
    val resolved = if (END_RESOLVES) base.resolveWhere(ownPending, "ended") else base
    // TARGETED: queued lines for this turn are handed back (rejected, acked);
    // today they stay queued for the next turn (spec/tui-turns #662).
    if (TARGETED) { ...resolved, queue: [] } else resolved

  pure def startTurn(st: S): S =
    { ...st, turnNo: st.turnNo + 1, running: true, parkedOn: -1 }
      .emit(ev("turn", st.turnNo + 1, -1, 0)).emit(ev("msg", st.turnNo + 1, -1, 0))

  // ---- state ----
  var s: S
  var lastAction: str

  pure def room(st: S, k: int): bool = st.log.length() + k <= MAX_LOG

  pure def isClient(st: S, c: int): bool =
    if (c == 0) LOCAL else st.cl.get(c).conn and not(st.cl.get(c).attaching)

  action commit(st: S, label: str): bool = all { s' = syncLocal(st), lastAction' = label }

  action init = all {
    s' = syncLocal({
      gen: 0, turnNo: 0, running: false, parkedOn: -1,
      reqs: Map(), nextReq: 1, log: [],
      cl: CLIENTS.mapBy(c => if (c == 0) { ...freshCl, conn: LOCAL } else freshCl),
      queue: [], cancels: [], steers: [], applied: [], unacked: 0, remoteCmds: 0,
    }),
    lastAction' = "init",
  }

  // Client c submits a line. Its intent is fixed by what it has seen: a new
  // prompt if it sees idle, steering for seenTurn otherwise.
  action send(c: int): bool = all {
    isClient(s, c), room(s, 3),
    val seen = s.cl.get(c).seenTurn
    if (not(s.running)) all {
      s.turnNo < MAX_TURNS,
      if (seen == 0)
        commit({ ...startTurn(s), steers: s.steers.append({ seen: 0, into: 0 }) }, "sendStart")
      else if (TARGETED)
        commit(s, "sendRejectedTurnEnded")
      else
        // on-submit sees busy? = false: the stale steer starts a fresh turn
        commit({ ...startTurn(s), steers: s.steers.append({ seen: seen, into: s.turnNo + 1 }) },
               "sendStaleStartsTurn")
    } else if (seen == s.turnNo or not(TARGETED))
      // on-submit sees busy? = true: queued as steering (untagged string)
      commit({ ...s, queue: s.queue.append({ seen: seen, src: c }) }, "sendQueued")
    else
      commit(s, "sendRejectedNotCurrent")
  }

  // The agent drains one steering line at a safe boundary of the running turn.
  action inject: bool = all {
    s.running, s.parkedOn < 0, s.queue.length() > 0, room(s, 1),
    val h = s.queue.head()
    commit({ ...s.emit(ev("msg", s.turnNo, -1, 0)), queue: s.queue.tail(),
             steers: s.steers.append({ seen: h.seen, into: s.turnNo }) }, "inject")
  }

  action naturalEnd: bool = all {
    s.running, s.parkedOn < 0, room(s, 3),
    commit(endTurn(s), "turnEnd"),
  }

  // A tool / permission check inside the running turn asks a question and parks.
  action toolRequest: bool = all {
    s.running, s.parkedOn < 0, s.nextReq <= MAX_REQS, room(s, 1),
    val i = s.nextReq
    commit({ ...s.emit(ev("req", s.turnNo, i, 0)),
             reqs: s.reqs.put(i, { turn: s.turnNo, gen: s.gen, status: "pending", wins: 0, ver: 0,
                                   deadline: TIMEOUTS }), // a turn-scoped request
             nextReq: i + 1, parkedOn: i }, "toolRequest")
  }

  // An idle-only slash command (/resume, /model) opens a picker. Local user,
  // or a remote client when remote "/" lines dispatch commands.
  action cmdRequest(c: int): bool = all {
    not(s.running), s.nextReq <= MAX_REQS, room(s, 1),
    if (c == 0) LOCAL else REMOTE_SLASH and isClient(s, c),
    pendingIds(s).forall(i => s.reqs.get(i).turn != 0),
    val i = s.nextReq
    commit({ ...s.emit(ev("req", 0, i, 0)),
             reqs: s.reqs.put(i, { turn: 0, gen: s.gen, status: "pending", wins: 0, ver: 0,
                                   deadline: TIMEOUTS }),
             nextReq: i + 1, remoteCmds: s.remoteCmds + (if (c == 0) 0 else 1) }, "cmdRequest")
  }

  // /model's picker refreshes its choices in place as discovery finishes
  // (model.fnl pick-model! :on-tick -> select.fnl replace-choices!).
  action updateChoices(i: int): bool = all {
    s.reqs.keys().contains(i), s.reqs.get(i).status == "pending",
    s.reqs.get(i).turn == 0, s.reqs.get(i).ver < MAX_VER, room(s, 1),
    val r = s.reqs.get(i)
    val st1 = { ...s, reqs: s.reqs.set(i, { ...r, ver: r.ver + 1 }) }
    commit(if (VERSIONED) st1.emit(ev("upd", 0, i, r.ver + 1)) else st1, "updateChoices")
  }

  pure def activeReq(st: S): int = pendingIds(st).fold(-1, (a, i) => if (i > a) i else a)

  // Client c answers request `aim`, which it has seen (possibly already resolved).
  action answer(c: int, aim: int): bool = all {
    isClient(s, c), s.cl.get(c).ever.contains(aim), room(s, 1),
    val target = if (ANSWER_BY_ID) aim else activeReq(s)
    val shown = verOf(s.cl.get(c).verSeen, aim)
    if (target < 0 or s.reqs.get(target).status != "pending")
      commit({ ...s, unacked: s.unacked + (if (ACK_ANSWERS) 0 else 1) }, "answerLate")
    else
      val r = s.reqs.get(target)
      if (VERSIONED and target == aim and shown != r.ver)
        commit(s, "answerRejectedStaleChoices")
      else
        val won = { ...s.emit(ev("res", 0, target, 0)),
                    reqs: s.reqs.set(target, { ...r, status: "answered", wins: r.wins + 1 }) }
        val rec = { aimed: aim, target: target, inScope: true,
                    fresh: r.gen == s.gen, verOk: shown == r.ver }
        if (r.turn > 0)
          if (s.running and s.parkedOn == target)
            commit({ ...won, parkedOn: -1, applied: s.applied.append(rec) }, "answerResumesTurn")
          else
            // accepted, but the turn it was issued for is gone
            commit({ ...won, applied: s.applied.append({ ...rec, inScope: false }) }, "answerForEndedTurn")
        else if (s.running)
          if (RECHECK)
            commit({ ...won, reqs: won.reqs.set(target, { ...r, status: "aborted", wins: r.wins + 1 }) },
                   "answerAbortedBusy")
          else
            // the command continuation runs while a turn is running
            commit({ ...won, applied: s.applied.append({ ...rec, inScope: false }) }, "answerCmdWhileBusy")
        else
          commit({ ...won, applied: s.applied.append(rec) }, "answerCmd")
  }

  action timeout(i: int): bool = all {
    s.reqs.keys().contains(i), s.reqs.get(i).deadline, s.reqs.get(i).status == "pending", room(s, 1),
    val st1 = s.setStatus(i, "timeout").emit(ev("res", 0, i, 0))
    commit(if (s.parkedOn == i) { ...st1, parkedOn: -1 } else st1, "timeout")
  }

  // Cancel from client c, aimed at the turn it sees.
  action cancel(c: int): bool = all {
    isClient(s, c), room(s, 3),
    val seen = s.cl.get(c).seenTurn
    all {
      seen > 0,
      if (s.running and (seen == s.turnNo or not(TARGETED)))
        commit({ ...endTurn(s), cancels: s.cancels.append({ seen: seen, hit: s.turnNo }) }, "cancel")
      else
        commit({ ...s, cancels: s.cancels.append({ seen: seen, hit: 0 }) }, "cancelNoop")
    }
  }

  // /reload is idle-only (session.fnl :idle-only? true; reload-request.drain!
  // runs only when not busy), so only idle-scoped requests can straddle it.
  action reload: bool = all {
    not(s.running), room(s, MAX_REQS),
    val st1 = { ...s, gen: s.gen + 1 }
    val idleP = pendingIds(s).filter(i => s.reqs.get(i).turn == 0)
    commit(if (RELOAD_RESOLVES) st1.resolveWhere(idleP, "cancelled") else st1, "reload")
  }

  // ---- remote stream ----
  action disconnect(c: int): bool = all {
    REMOTES.contains(c), s.cl.get(c).conn,
    val cc = s.cl.get(c)
    commit({ ...s, cl: s.cl.set(c, { ...cc, conn: false, attaching: false, lastMax: cc.cursor }) },
           "disconnect")
  }

  pure def snapshotCl(st: S, cc: Cl): Cl =
    val P = pendingIds(st)
    { ...cc, conn: true, attaching: false, cursor: st.log.length(), base: 0,
      got: range(0, st.log.length()).foldl([], (acc, i) =>
             if (persisted(st.log[i])) acc.append(i + 1) else acc),
      seenTurn: if (st.running) st.turnNo else 0,
      known: P, ever: cc.ever.union(P),
      verSeen: P.fold(cc.verSeen, (m, i) => m.put(i, st.reqs.get(i).ver)) }

  action connect(c: int, resume: bool): bool = all {
    REMOTES.contains(c), not(s.cl.get(c).conn),
    val cc = s.cl.get(c)
    val len = s.log.length()
    if (REPLAY == "ring")
      if (resume and cc.lastMax > 0 and cc.lastMax >= len - RING)
        commit({ ...s, cl: s.cl.set(c, { ...cc, conn: true, attaching: false, cursor: cc.lastMax,
                                          base: cc.lastMax, got: [] }) }, "connectResume")
      else
        commit({ ...s, cl: s.cl.set(c, snapshotCl(s, cc)) }, "connectSnapshot")
    else
      // #396: the client rebuilds from the JSONL replay; no resume point.
      val fresh = { ...freshCl, ever: cc.ever, conn: true, attaching: true, replayPos: 0,
                    replayEnd: if (REPLAY == "jsonlGap") len else -1,
                    cursor: if (REPLAY == "jsonlGap") 0 else len }
      commit({ ...s, cl: s.cl.set(c, fresh) }, "connectReplay")
  }

  pure def replayLimit(st: S, cc: Cl): int = if (cc.replayEnd < 0) st.log.length() else cc.replayEnd

  // One yielding chunk of the JSONL replay: the next persisted line.
  action replayStep(c: int): bool = all {
    REMOTES.contains(c),
    val cc = s.cl.get(c)
    all {
      cc.conn, cc.attaching, cc.replayPos < replayLimit(s, cc),
      val e = s.log[cc.replayPos]
      val c1 = { ...cc, replayPos: cc.replayPos + 1,
                        got: if (persisted(e)) cc.got.append(cc.replayPos + 1) else cc.got }
      commit({ ...s, cl: s.cl.set(c, c1) }, "replayStep")
    }
  }

  action finishReplay(c: int): bool = all {
    REMOTES.contains(c),
    val cc = s.cl.get(c)
    all {
      cc.conn, cc.attaching, cc.replayPos >= replayLimit(s, cc),
      val c1 = { ...cc, attaching: false,
                        cursor: if (REPLAY == "jsonlGap") s.log.length() else cc.cursor }
      commit({ ...s, cl: s.cl.set(c, c1) }, "finishReplay")
    }
  }

  action deliver(c: int): bool = all {
    REMOTES.contains(c),
    val cc = s.cl.get(c)
    all {
      cc.conn, cc.cursor < s.log.length(),
      not(cc.attaching) or REPLAY == "jsonlDup",
      REPLAY != "ring" or cc.cursor >= s.log.length() - RING,
      commit({ ...s, cl: s.cl.set(c, deliverOne(cc, s.log)) }, "deliver"),
    }
  }

  // Ring overrun: a slow client is dropped and must resume (and will get a snapshot).
  action overflow(c: int): bool = all {
    REPLAY == "ring", REMOTES.contains(c),
    val cc = s.cl.get(c)
    all {
      cc.conn, cc.cursor < s.log.length() - RING,
      commit({ ...s, cl: s.cl.set(c, { ...cc, conn: false, lastMax: cc.cursor }) }, "overflow"),
    }
  }

  action step = {
    nondet c = CLIENTS.oneOf()
    nondet r = REMOTES.oneOf()
    nondet i = 1.to(MAX_REQS).oneOf()
    nondet resume = Bool.oneOf()
    any {
      send(c), inject, naturalEnd, toolRequest, cmdRequest(c), updateChoices(i),
      answer(c, i), timeout(i), cancel(c), reload,
      disconnect(r), connect(r, resume), replayStep(r), finishReplay(r), deliver(r), overflow(r),
    }
  }

  // ---- invariants ----

  // At most one turn is open (turn-started without its end) at any time.
  val singleTurn =
    s.log.foldl(0, (n, e) => if (e.kind == "turn") n + 1 else if (e.kind == "end") n - 1 else n) <= 1

  // No request is resolved by two answers.
  val resolvedAtMostOnce = s.reqs.keys().forall(i => s.reqs.get(i).wins <= 1)

  // Every answer that loses gets a visible rejection to its sender.
  val answersAcked = s.unacked == 0

  // An answer resolves the request it was made for.
  val answerHitsItsRequest = s.applied.foldl(true, (ok, a) => ok and a.aimed == a.target)

  // A resolution is applied only in the context it was issued for: a turn's
  // request while that turn runs; a command's request while idle.
  val resolutionInScope = s.applied.foldl(true, (ok, a) => ok and a.inScope)

  // A resolution never drives a continuation captured before a /reload.
  val noStaleContinuation = s.applied.foldl(true, (ok, a) => ok and a.fresh)

  // An answer picks from the choice list the answerer was shown.
  val answerMatchesShownChoices = s.applied.foldl(true, (ok, a) => ok and a.verOk)

  // No request outlives the turn it was issued from.
  val noPendingForEndedTurn = pendingIds(s).forall(i =>
    val r = s.reqs.get(i)
    r.turn == 0 or (s.running and r.turn == s.turnNo))

  // Cancel stops the turn the sender saw, or nothing.
  val cancelHitsSeenTurn = s.cancels.foldl(true, (ok, x) => ok and (x.hit == 0 or x.hit == x.seen))

  // A line reaches the turn its sender saw (seen idle -> its own new turn).
  val steeringReachesSeenTurn = s.steers.foldl(true, (ok, x) => ok and x.into == x.seen)

  pure def live(st: S, c: int): bool = st.cl.get(c).conn and not(st.cl.get(c).attaching)

  val noDuplicateDelivery = REMOTES.forall(c =>
    val g = s.cl.get(c).got
    g.length() == g.foldl(Set(), (a, x) => a.union(Set(x))).size())

  val inOrderDelivery = REMOTES.forall(c =>
    val g = s.cl.get(c).got
    g.indices().forall(k => k == 0 or g[k - 1] < g[k]))

  // A reattached client has every persisted event between its resume point
  // and the newest event it has received.
  val noSilentGap = REMOTES.forall(c =>
    val cc = s.cl.get(c)
    val g = cc.got.foldl(Set(), (a, x) => a.union(Set(x)))
    val hi = maxOf(cc.got)
    not(live(s, c)) or s.log.indices().forall(k =>
      not(persisted(s.log[k])) or k + 1 <= cc.base or k + 1 > hi or g.contains(k + 1)))

  pure def caughtUp(st: S, c: int): bool = live(st, c) and st.cl.get(c).cursor == st.log.length()

  // A caught-up client knows every pending request (so it can answer it).
  val caughtUpSeesPending = REMOTES.forall(c =>
    not(caughtUp(s, c)) or pendingIds(s).subseteq(s.cl.get(c).known))

  // A caught-up client knows whether a turn is running, and which.
  val caughtUpSeesTurn = REMOTES.forall(c =>
    not(caughtUp(s, c)) or s.cl.get(c).seenTurn == (if (s.running) s.turnNo else 0))

  // Safety, not liveness: in every state each pending request has a party
  // that could resolve it: the in-process presenter, a connected remote
  // client, or a deadline armed on the request itself. It does not claim
  // that anyone answers or that the deadline fires (no fairness is assumed,
  // see spec/README.md "Kinds of evidence").
  val pendingHasPossibleResolver = pendingIds(s).forall(i =>
    LOCAL or s.reqs.get(i).deadline or REMOTES.exists(c => s.cl.get(c).conn))

  // A remote client cannot dispatch slash commands (#397: input only
  // reaches the steering/follow-up queues).
  val remoteNoCommands = s.remoteCmds == 0

  val allInvariants = and {
    singleTurn, resolvedAtMostOnce, answersAcked, answerHitsItsRequest,
    resolutionInScope, noStaleContinuation, answerMatchesShownChoices,
    noPendingForEndedTurn, cancelHitsSeenTurn, steeringReachesSeenTurn,
    noDuplicateDelivery, inOrderDelivery, noSilentGap, caughtUpSeesPending,
    caughtUpSeesTurn, pendingHasPossibleResolver, remoteNoCommands,
  }
}

// #394/#396/#397/#398 as written, with the local TUI attached.
module issue {
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
               TIMEOUTS = false, TARGETED = false, REPLAY = "jsonlGap",
               RECHECK = false, VERSIONED = false, LOCAL = true,
               REMOTE_SLASH = false, RELOAD_RESOLVES = false).*
}

// Same, but the yielding JSONL replay subscribes to live events first.
module issueDup {
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
               TIMEOUTS = false, TARGETED = false, REPLAY = "jsonlDup",
               RECHECK = false, VERSIONED = false, LOCAL = true,
               REMOTE_SLASH = false, RELOAD_RESOLVES = false).*
}

// serve alongside a headless presenter (#396: "runs alongside any active presenter").
module headless {
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = false, END_RESOLVES = false,
               TIMEOUTS = false, TARGETED = false, REPLAY = "jsonlGap",
               RECHECK = false, VERSIONED = false, LOCAL = false,
               REMOTE_SLASH = false, RELOAD_RESOLVES = false).*
}

// The web presenter code #396 says to reuse: /select carries a bare index
// applied to the active select; /input dispatches "/" lines as commands.
module webReuse {
  import serve(ANSWER_BY_ID = false, ACK_ANSWERS = false, END_RESOLVES = false,
               TIMEOUTS = false, TARGETED = false, REPLAY = "jsonlGap",
               RECHECK = false, VERSIONED = false, LOCAL = true,
               REMOTE_SLASH = true, RELOAD_RESOLVES = false).*
}

// Recommended protocol, headless (the harder case).
module proposed {
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = true, END_RESOLVES = true,
               TIMEOUTS = true, TARGETED = true, REPLAY = "ring",
               RECHECK = true, VERSIONED = true, LOCAL = false,
               REMOTE_SLASH = false, RELOAD_RESOLVES = true).*
}

// Recommended protocol with the local TUI attached.
module proposedTui {
  import serve(ANSWER_BY_ID = true, ACK_ANSWERS = true, END_RESOLVES = true,
               TIMEOUTS = true, TARGETED = true, REPLAY = "ring",
               RECHECK = true, VERSIONED = true, LOCAL = true,
               REMOTE_SLASH = false, RELOAD_RESOLVES = true).*
}
