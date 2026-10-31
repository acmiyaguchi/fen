// Abstract specification of process job (#670): process group lifecycle
// and output capture.
//
// Refined and used by tools (process execution, popen cancellation, output envelope)
// and subagents.
//
// The contract:
// 1. Spawns an argv leader in a fresh process group (session) with potential group
//    members (background or child processes).
// 2. Output is streamed and capped: body truncation leaves space for the status
//    trailer, and the exit tag is never lost (result envelope #652).
// 3. At deadline, SIGTERM is sent to the group. After grace period, SIGKILL is sent.
// 4. On cancel (abort!), SIGKILL is sent immediately to the whole group (#659).
// 5. On completion, the leader is reaped and any abnormal exit (timeout or cancel)
//    guarantees no member of the process group survives (#651).
//
// Pure definitions only, so concrete models can import them and check that
// their mapped state refines absNext.
module jobAbstract {
  pure val BODY_LIMIT: int = 2
  pure val TRAILER_SIZE: int = 1
  pure val MAX_LIMIT: int = 3

  type Abs = {
    phase: str,           // "idle" | "running" | "done"
    leaderAlive: bool,    // command session leader is alive
    membersAlive: bool,   // group members (backgrounded / nested processes) are alive
    termSent: bool,       // SIGTERM sent to group at deadline / timeout
    killSent: bool,       // SIGKILL sent to group (on grace expiry, cancel, or cleanup)
    timedOut: bool,       // deadline elapsed
    cancelled: bool,      // cancel requested at a yield
    outLen: int,          // captured output units/bytes (bounded)
    truncated: bool,      // whether body output exceeded limit and was capped
    hasTrailer: bool,     // status trailer ("[exit N]" / timeout / cancelled) attached
    outcome: str,         // "none" | "ok" | "error" | "timeout" | "cancelled"
  }

  pure val absInit: Abs = {
    phase: "idle",
    leaderAlive: false,
    membersAlive: false,
    termSent: false,
    killSent: false,
    timedOut: false,
    cancelled: false,
    outLen: 0,
    truncated: false,
    hasTrailer: false,
    outcome: "none",
  }

  // Spawn command leader and group members in a fresh session.
  pure def spawn(a: Abs, b: Abs): bool = and {
    a.phase == "idle",
    b.phase == "running",
    b.leaderAlive,
    b.membersAlive,
    not(b.termSent),
    not(b.killSent),
    not(b.timedOut),
    not(b.cancelled),
    b.outLen == 0,
    not(b.truncated),
    not(b.hasTrailer),
    b.outcome == "none",
  }

  // Append streamed output, observing the body cap.
  pure def appendOutput(a: Abs, b: Abs): bool = and {
    a.phase == "running",
    b.phase == a.phase,
    b.leaderAlive == a.leaderAlive,
    b.membersAlive == a.membersAlive,
    b.termSent == a.termSent,
    b.killSent == a.killSent,
    b.timedOut == a.timedOut,
    b.cancelled == a.cancelled,
    b.hasTrailer == a.hasTrailer,
    b.outcome == a.outcome,
    if (a.outLen < BODY_LIMIT)
      and { b.outLen == a.outLen + 1, b.truncated == a.truncated }
    else
      and { b.outLen == BODY_LIMIT, b.truncated == true },
  }

  // Process group members exit.
  pure def leaderExit(a: Abs, b: Abs): bool = and {
    a.phase == "running",
    a.leaderAlive,
    b == { ...a, leaderAlive: false },
  }

  pure def memberExit(a: Abs, b: Abs): bool = and {
    a.phase == "running",
    a.membersAlive,
    b == { ...a, membersAlive: false },
  }

  // Deadline elapsed: SIGTERM sent to process group.
  pure def timeout(a: Abs, b: Abs): bool = and {
    a.phase == "running",
    not(a.timedOut),
    not(a.termSent),
    b.phase == a.phase,
    b.timedOut,
    b.termSent,
    b.killSent == a.killSent,
    b.cancelled == a.cancelled,
    b.outLen == a.outLen,
    b.truncated == a.truncated,
    b.hasTrailer == a.hasTrailer,
    b.outcome == a.outcome,
    (not(b.leaderAlive) or a.leaderAlive),
    (not(b.membersAlive) or a.membersAlive),
  }

  // Grace window elapsed after SIGTERM: SIGKILL unconditionally kills all remaining processes.
  pure def graceExpired(a: Abs, b: Abs): bool = and {
    a.phase == "running",
    a.termSent,
    not(a.killSent),
    b.phase == a.phase,
    b.timedOut == a.timedOut,
    b.cancelled == a.cancelled,
    b.termSent == a.termSent,
    b.killSent == true,
    b.leaderAlive == false,
    b.membersAlive == false,
    b.outLen == a.outLen,
    b.truncated == a.truncated,
    b.hasTrailer == a.hasTrailer,
    b.outcome == a.outcome,
  }

  // Cancel requested (abort!): SIGKILL unconditionally sent to whole group.
  pure def cancel(a: Abs, b: Abs): bool = and {
    a.phase == "running",
    not(a.cancelled),
    b.phase == a.phase,
    b.timedOut == a.timedOut,
    b.termSent == a.termSent,
    b.cancelled == true,
    b.killSent == true,
    b.leaderAlive == false,
    b.membersAlive == false,
    b.outLen == a.outLen,
    b.truncated == a.truncated,
    b.hasTrailer == a.hasTrailer,
    b.outcome == a.outcome,
  }

  // Finish: leader is reaped and final status envelope is attached.
  // Abnormal exit (timeout or cancel) guarantees all group members are dead (#651).
  pure def finish(a: Abs, b: Abs): bool = and {
    a.phase == "running",
    not(a.leaderAlive),
    b.phase == "done",
    b.leaderAlive == false,
    b.termSent == a.termSent,
    b.timedOut == a.timedOut,
    b.cancelled == a.cancelled,
    b.truncated == a.truncated,
    b.hasTrailer == true,
    b.outLen == a.outLen + TRAILER_SIZE,
    if (a.timedOut or a.cancelled)
      and {
        b.membersAlive == false,
        b.killSent == (a.killSent or a.membersAlive),
        b.outcome == (if (a.cancelled) "cancelled" else "timeout"),
      }
    else
      and {
        b.membersAlive == a.membersAlive,
        b.killSent == a.killSent,
        Set("ok", "error").contains(b.outcome),
      },
  }

  pure def absNext(a: Abs, b: Abs): bool = or {
    a == b,
    spawn(a, b),
    appendOutput(a, b),
    leaderExit(a, b),
    memberExit(a, b),
    timeout(a, b),
    graceExpired(a, b),
    cancel(a, b),
    finish(a, b),
  }

  // ---- properties every refining owner inherits ----

  // A timed-out or cancelled job leaves no live process in its group (#651).
  pure def noLiveProcessAfterAbnormal(a: Abs): bool =
    (a.phase == "done" and (a.timedOut or a.cancelled)) implies not(a.leaderAlive or a.membersAlive)

  // A finished job has reaped its session leader.
  pure def leaderReapedWhenDone(a: Abs): bool =
    a.phase == "done" implies not(a.leaderAlive)

  // SIGKILL is only ever sent on timeout or cancel.
  pure def killOnlyAbnormal(a: Abs): bool =
    a.killSent implies (a.timedOut or a.cancelled)

  // The status trailer is attached if and only if the job has finished.
  pure def trailerWhenDone(a: Abs): bool =
    a.hasTrailer == (a.phase == "done")

  // The outcome is consistent with phase and cause.
  pure def outcomeConsistent(a: Abs): bool = and {
    (a.outcome == "none") == (a.phase != "done"),
    a.outcome == "cancelled" implies a.cancelled,
    a.outcome == "timeout" implies a.timedOut,
  }

  // Output bytes/units never exceed the limit.
  pure def outputWithinLimit(a: Abs): bool =
    a.outLen <= MAX_LIMIT

  pure def absInv(a: Abs): bool = and {
    noLiveProcessAfterAbnormal(a),
    leaderReapedWhenDone(a),
    killOnlyAbnormal(a),
    trailerWhenDone(a),
    outcomeConsistent(a),
    outputWithinLimit(a),
  }
}
