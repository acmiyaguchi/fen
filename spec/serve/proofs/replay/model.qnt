// Proof model: the replay cursor (#396, serve FINDINGS V8; guarantees 1-2).
//
// Only the state the contract needs: the process's event log as two fixed
// maps over seqs 1..MAX_LOG (is the event persisted in the session JSONL, and
// the value of the non-persisted state after it), and one remote client.
// A persisted event is a message; a non-persisted one changes the state a
// client must know to act (whether a turn runs, which requests are pending),
// abstracted to a value in VALS. The client keeps the seqs delivered on its
// current connection, the highest one, and its view of that state.
//
// REPLAY selects the attach design, as in the integration model:
//   "jsonlGap": #396 replays the JSONL snapshot, then follows live from the
//               end of replay (events during the yielding replay are skipped);
//   "jsonlDup": follows live from attach while the yielding replay reads the
//               growing JSONL (events during replay arrive twice);
//   "ring":     proposed: resume(after-seq) from a bounded ring, else a reset
//               plus a snapshot (messages and state) at a recorded seq, then
//               live by cursor; a client that falls behind the ring is dropped.
// One client is enough: clients share nothing but the log.
module replay {
  const REPLAY: str

  pure val MAX_LOG = 6
  pure val RING = 2
  pure val SEQS = 1.to(MAX_LOG)
  pure val POS = 0.to(MAX_LOG)
  pure val VALS = 0.to(2)
  pure val LABELS = Set("init", "emitMsg", "emitState", "connectResume", "connectSnapshot",
    "connectReplay", "replayStep", "finishReplay", "deliver", "overflow", "disconnect")

  // process
  var len: int
  var cur: int                 // current state value (the value after seq len)
  var logP: int -> bool        // seq -> persisted in the session JSONL
  var logV: int -> int         // seq -> state value after the event
  // the remote client
  var conn: bool
  var attaching: bool
  var cursor: int              // live: seqs consumed
  var replayPos: int
  var replayEnd: int           // -1: replay reads the growing file
  var base: int                // seq the client already had at (re)attach
  var lastMax: int             // last consumed seq, kept across disconnect
  var hi: int                  // highest seq delivered on this connection
  var got: Set[int]            // seqs delivered on this connection
  var view: int                // the state value the client believes
  // ghost: sticky, false once a seq arrived twice / out of order
  var dupOk: bool
  var orderOk: bool
  var lastAction: str

  pure def stateAt(v: int -> int, k: int): int = if (k <= 0) 0 else v.get(k)

  action logTo(l: int, c: int, p: int -> bool, v: int -> int): bool = all {
    len' = l, cur' = c, logP' = p, logV' = v,
  }
  action keepLog: bool = logTo(len, cur, logP, logV)

  action clientTo(cn: bool, at: bool, cu: int, rp: int, re: int, ba: int, lm: int,
                  h: int, g: Set[int], vw: int, d: bool, o: bool, label: str): bool = all {
    conn' = cn, attaching' = at, cursor' = cu, replayPos' = rp, replayEnd' = re,
    base' = ba, lastMax' = lm, hi' = h, got' = g, view' = vw, dupOk' = d, orderOk' = o,
    lastAction' = label,
  }
  action keepClient(label: str): bool =
    clientTo(conn, attaching, cursor, replayPos, replayEnd, base, lastMax, hi, got, view,
             dupOk, orderOk, label)

  action init = all {
    logTo(0, 0, SEQS.mapBy(_k => false), SEQS.mapBy(_k => 0)),
    clientTo(false, false, 0, 0, 0, 0, 0, 0, Set(), 0, true, true, "init"),
  }

  // The process appends a message (persisted; the state is unchanged).
  action emitMsg: bool = all {
    len < MAX_LOG,
    logTo(len + 1, cur, logP.set(len + 1, true), logV.set(len + 1, cur)),
    keepClient("emitMsg"),
  }

  // The process emits a state event (turn-started, select-requested, ...).
  action emitState(v: int): bool = all {
    len < MAX_LOG, v != cur,
    logTo(len + 1, v, logP.set(len + 1, false), logV.set(len + 1, v)),
    keepClient("emitState"),
  }

  action connect(resume: bool): bool = all {
    not(conn), keepLog,
    if (REPLAY == "ring")
      if (resume and lastMax > 0 and lastMax >= len - RING)
        // resume from the ring: replay from lastMax + 1, then live
        clientTo(true, false, lastMax, 0, 0, lastMax, lastMax, 0, Set(), view,
                 dupOk, orderOk, "connectResume")
      else
        // reset: a snapshot of messages and state taken at seq len
        clientTo(true, false, len, 0, 0, 0, lastMax, len,
                 SEQS.filter(k => k <= len and logP.get(k)), cur,
                 dupOk, orderOk, "connectSnapshot")
    else
      // #396: rebuild from the JSONL replay; no resume point, no state
      clientTo(true, true, if (REPLAY == "jsonlGap") 0 else len, 0,
               if (REPLAY == "jsonlGap") len else -1, 0, lastMax, 0, Set(), 0,
               dupOk, orderOk, "connectReplay"),
  }

  def replayLimit: int = if (replayEnd < 0) len else replayEnd

  // Delivery bookkeeping for seq k.
  pure def gotWith(g: Set[int], k: int): Set[int] = g.union(Set(k))
  pure def hiWith(h: int, k: int): int = if (k > h) k else h

  // One yielding chunk of the JSONL replay: the next line, if persisted.
  action replayStep: bool =
    val k = replayPos + 1
    all {
      conn, attaching, replayPos < replayLimit, keepLog,
      if (logP.get(k))
        clientTo(conn, attaching, cursor, k, replayEnd, base, lastMax, hiWith(hi, k),
                 gotWith(got, k), view, dupOk and not(got.contains(k)), orderOk and k > hi,
                 "replayStep")
      else
        clientTo(conn, attaching, cursor, k, replayEnd, base, lastMax, hi, got, view,
                 dupOk, orderOk, "replayStep"),
    }

  action finishReplay: bool = all {
    conn, attaching, replayPos >= replayLimit, keepLog,
    clientTo(conn, false, if (REPLAY == "jsonlGap") len else cursor, replayPos, replayEnd,
             base, lastMax, hi, got, view, dupOk, orderOk, "finishReplay"),
  }

  // The next live event reaches the client.
  action deliver: bool =
    val k = cursor + 1
    all {
      conn, cursor < len,
      not(attaching) or REPLAY == "jsonlDup",
      REPLAY != "ring" or cursor >= len - RING,
      keepLog,
      clientTo(conn, attaching, k, replayPos, replayEnd, base, lastMax, hiWith(hi, k),
               gotWith(got, k), if (logP.get(k)) view else logV.get(k),
               dupOk and not(got.contains(k)), orderOk and k > hi, "deliver"),
    }

  // Ring overrun: a slow client is dropped and must reattach.
  action overflow: bool = all {
    REPLAY == "ring", conn, cursor < len - RING, keepLog,
    clientTo(false, false, cursor, replayPos, replayEnd, base, cursor, hi, got, view,
             dupOk, orderOk, "overflow"),
  }

  action disconnect: bool = all {
    conn, keepLog,
    clientTo(false, false, cursor, replayPos, replayEnd, base, cursor, hi, got, view,
             dupOk, orderOk, "disconnect"),
  }

  action step = {
    nondet v = VALS.oneOf()
    nondet resume = Bool.oneOf()
    any { emitMsg, emitState(v), connect(resume), replayStep, finishReplay, deliver,
          overflow, disconnect }
  }

  // ---- invariants ----

  def live: bool = conn and not(attaching)

  // No seq reaches the client twice on one connection.
  val noDuplicateDelivery = dupOk
  // Seqs reach the client in increasing order on one connection.
  val inOrderDelivery = orderOk
  // A live client has every persisted event between its resume point and
  // the newest event it has received.
  val noSilentGap = live implies SEQS.forall(k =>
    not(k <= len and logP.get(k)) or k <= base or k > hi or got.contains(k))
  // A caught-up client knows the current state (whether a turn runs, which
  // requests are pending: the integration model's caughtUpSeesTurn and
  // caughtUpSeesPending).
  val caughtUpSeesState = (live and cursor == len) implies view == cur

  val allInvariants = and { noDuplicateDelivery, inOrderDelivery, noSilentGap, caughtUpSeesState }

  // Inductive strengthening: every variable in its finite domain; the log is
  // consistent (a message keeps the state, cur is the state after seq len);
  // a connected client's view is the state at its cursor, and it has every
  // persisted seq in (base, cursor] and nothing beyond its cursor; a
  // disconnected client's view is the state at the seq it would resume from.
  val inductiveInv = and {
    len.in(POS), cur.in(VALS), logP.in(setOfMaps(SEQS, Bool)), logV.in(setOfMaps(SEQS, VALS)),
    conn.in(Bool), attaching.in(Bool), cursor.in(POS), replayPos.in(POS),
    replayEnd.in(Set(-1).union(POS)), base.in(POS), lastMax.in(POS), hi.in(POS),
    got.in(powerset(SEQS)), view.in(VALS), dupOk.in(Bool), orderOk.in(Bool),
    lastAction.in(LABELS),
    not(attaching),
    cur == stateAt(logV, len),
    SEQS.forall(k => (k <= len and logP.get(k)) implies logV.get(k) == stateAt(logV, k - 1)),
    cursor <= len, lastMax <= len,
    conn implies and {
      view == stateAt(logV, cursor), base <= cursor, hi <= cursor,
      got.forall(k => k <= cursor),
      SEQS.forall(k => (k <= cursor and k > base and logP.get(k)) implies got.contains(k)),
    },
    not(conn) implies view == stateAt(logV, lastMax),
    allInvariants,
  }
}

// #396 as written: JSONL snapshot, then live from the end of replay.
module issue {
  import replay(REPLAY = "jsonlGap").*
}

// #396 the other way round: live from attach, replay reads the growing file.
module issueDup {
  import replay(REPLAY = "jsonlDup").*
}

// Proposed: seq-numbered ring with resume, else snapshot at a recorded seq.
module proposed {
  import replay(REPLAY = "ring").*
}
