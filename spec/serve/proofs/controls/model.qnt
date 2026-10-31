// Proof model: targeted controls (#397, serve FINDINGS V1, guarantee 3).
//
// Only the state the contract needs: whether a turn runs and its id, what
// each client last saw (0 = idle, t = turn t running), and the steering
// queue as the set of turn tags its lines carry. A client's view is whatever
// it last observed, so it can lag the agent by any number of turns.
//
// TARGETED = false is #397 as written: cancel uses the TUI path
// (interactive.fnl request-cancel names no turn) and lines go into the
// untagged steering queue, so `submit` decides prompt-or-steer from busy? at
// processing time. TARGETED = true is the proposed protocol: every control
// carries the turn its sender saw and is rejected (acked) when that is not
// the running turn; a turn's unconsumed lines are handed back at its end.
//
// The queue is a set of tags, so `inject` takes any queued line, not the
// oldest: an over-approximation of FIFO that the property must survive.
module controls {
  const TARGETED: bool

  pure val CLIENTS = Set(0, 1, 2)
  pure val MAX_TURNS = 3
  pure val TURNS = 0.to(MAX_TURNS)
  pure val LABELS = Set("init", "observe", "sendStart", "sendRejectedTurnEnded",
    "sendStaleStartsTurn", "sendQueued", "sendRejectedNotCurrent", "inject",
    "turnEnd", "cancel", "cancelNoop")

  var running: bool
  var turnNo: int              // id of the running or last turn (0: none yet)
  var seen: int -> int         // client -> turn it believes is running (0 = idle)
  var queue: Set[int]          // turn tags of queued steering lines
  // ghost: sticky, false once a control hit a turn other than its sender's
  var cancelOk: bool
  var steerOk: bool
  var lastAction: str

  action init = all {
    running' = false, turnNo' = 0, seen' = CLIENTS.mapBy(_c => 0),
    queue' = Set(), cancelOk' = true, steerOk' = true, lastAction' = "init",
  }

  // The bus delivers the current turn state to client c.
  action observe(c: int): bool = all {
    seen' = seen.set(c, if (running) turnNo else 0),
    running' = running, turnNo' = turnNo, queue' = queue,
    cancelOk' = cancelOk, steerOk' = steerOk, lastAction' = "observe",
  }

  // A turn starts for a line whose sender saw `tag` (0: it saw idle).
  action startFor(tag: int, label: str): bool = all {
    turnNo < MAX_TURNS,
    running' = true, turnNo' = turnNo + 1, seen' = seen, queue' = queue,
    cancelOk' = cancelOk, steerOk' = (steerOk and tag == 0), lastAction' = label,
  }

  action unchanged(label: str): bool = all {
    running' = running, turnNo' = turnNo, seen' = seen, queue' = queue,
    cancelOk' = cancelOk, steerOk' = steerOk, lastAction' = label,
  }

  // Client c submits a line: a prompt if it sees idle, steering for the
  // turn it sees otherwise.
  action send(c: int): bool =
    val t = seen.get(c)
    if (not(running))
      if (t == 0) startFor(0, "sendStart")
      else if (TARGETED) unchanged("sendRejectedTurnEnded")
      // on-submit sees busy? = false: the stale steer starts a fresh turn
      else startFor(t, "sendStaleStartsTurn")
    else if (t == turnNo or not(TARGETED))
      // queued as steering (#397: an untagged string; here tagged with t)
      all {
        queue' = queue.union(Set(t)),
        running' = running, turnNo' = turnNo, seen' = seen,
        cancelOk' = cancelOk, steerOk' = steerOk, lastAction' = "sendQueued",
      }
    else unchanged("sendRejectedNotCurrent")

  // The running turn drains one steering line at a safe boundary.
  action inject: bool = {
    nondet h = queue.oneOf()
    all {
      running, queue.contains(h),
      queue' = queue.exclude(Set(h)), steerOk' = (steerOk and h == turnNo),
      running' = running, turnNo' = turnNo, seen' = seen,
      cancelOk' = cancelOk, lastAction' = "inject",
    }
  }

  // The running turn ends. Today its unconsumed lines stay queued for the
  // next turn (tui-turns #662); TARGETED hands them back.
  action endTurn(hit: bool, label: str): bool = all {
    running,
    running' = false, turnNo' = turnNo, seen' = seen,
    queue' = if (TARGETED) Set() else queue,
    cancelOk' = (cancelOk and hit), steerOk' = steerOk, lastAction' = label,
  }

  action naturalEnd: bool = endTurn(true, "turnEnd")

  // Client c cancels the turn it sees.
  action cancel(c: int): bool =
    val t = seen.get(c)
    all {
      t > 0,
      if (running and (t == turnNo or not(TARGETED))) endTurn(t == turnNo, "cancel")
      else unchanged("cancelNoop"),
    }

  action step = {
    nondet c = CLIENTS.oneOf()
    any { observe(c), send(c), inject, naturalEnd, cancel(c) }
  }

  // ---- invariants ----

  // Cancel stops the turn the sender saw, or nothing.
  val cancelHitsSeenTurn = cancelOk
  // A line reaches the turn its sender saw (seen idle: its own new turn).
  val steeringReachesSeenTurn = steerOk

  val allInvariants = cancelHitsSeenTurn and steeringReachesSeenTurn

  // Inductive strengthening: every variable in its finite domain, a client
  // never sees a turn that has not started, and every queued line is tagged
  // with the running turn (sends are checked against it, and turn end
  // empties the queue).
  val inductiveInv = and {
    running.in(Bool), turnNo.in(TURNS), seen.in(setOfMaps(CLIENTS, TURNS)),
    queue.in(powerset(TURNS)), cancelOk.in(Bool), steerOk.in(Bool),
    lastAction.in(LABELS),
    CLIENTS.forall(c => seen.get(c) <= turnNo),
    queue.forall(t => running and t == turnNo),
    allInvariants,
  }
}

// #397 as written: untargeted cancel, untagged steering queue.
module issue {
  import controls(TARGETED = false).*
}

// Proposed: controls carry the seen turn; turn end hands lines back.
module proposed {
  import controls(TARGETED = true).*
}
