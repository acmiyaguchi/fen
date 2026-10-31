// Abstract specification of task table (#671): one task table with turn-keyed
// ownership and fault-isolated step.
//
// Refined and used by scheduler (presenter loop, active poll cadence, cancel arm),
// tui-turns (tab-keyed turns, side chat ownership, draft and Ctrl-C routing), and serve.
//
// The contract:
// 1. One central cooperative task table tracks all live work.
// 2. Each task entry carries its owning turn/tab id from start to finish. Cancel
//    requests and cancel arms (second-press quit) are strictly turn-keyed and
//    never leak to other turns (#636, #660, #661, #663).
// 3. Driver step executes tasks under xpcall: an error in one task is caught and
//    the task is retired without crashing the scheduler loop (#635).
// 4. Polling cadence is active (e.g. 30ms) if and only if runnable work is pending;
//    otherwise idle (300ms) (#637).
//
// Pure definitions only, so concrete models can import them and check that
// their mapped state refines absNext.
module tasksAbstract {
  type Abs = {
    // Task slot 1
    t1Status: str,      // "none" | "ready" | "done"
    t1Owner: int,       // 0 when none; 1, 2 for owner turn
    t1Cancel: bool,     // cancel requested for task 1
    t1Armed: bool,      // cancel arm held by task 1 (second-press quit)
    // Task slot 2
    t2Status: str,      // "none" | "ready" | "done"
    t2Owner: int,       // 0 when none; 1, 2 for owner turn
    t2Cancel: bool,     // cancel requested for task 2
    t2Armed: bool,      // cancel arm held by task 2
    // Table-level scheduler state
    anyRunnable: bool,  // true iff at least one task is ready
    pollActive: bool,   // true iff polling at active cadence (matches anyRunnable)
    faultCaught: bool,  // a task fault was caught and isolated by the driver
  }

  pure val absInit: Abs = {
    t1Status: "none",
    t1Owner: 0,
    t1Cancel: false,
    t1Armed: false,
    t2Status: "none",
    t2Owner: 0,
    t2Cancel: false,
    t2Armed: false,
    anyRunnable: false,
    pollActive: false,
    faultCaught: false,
  }

  // Register a new task under owner.
  pure def spawn(a: Abs, b: Abs): bool = or {
    // Spawn in slot 1
    and {
      a.t1Status == "none",
      b.t1Status == "ready",
      b.t1Owner > 0,
      not(b.t1Cancel),
      not(b.t1Armed),
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      b.anyRunnable == true,
      b.pollActive == true,
      not(b.faultCaught),
    },
    // Spawn in slot 2
    and {
      a.t2Status == "none",
      b.t2Status == "ready",
      b.t2Owner > 0,
      not(b.t2Cancel),
      not(b.t2Armed),
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      b.anyRunnable == true,
      b.pollActive == true,
      not(b.faultCaught),
    },
  }

  // Request cancel strictly for the task matching owner.
  pure def requestCancel(a: Abs, b: Abs): bool = or {
    and {
      a.t1Status != "none",
      b.t1Cancel == true,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Armed == a.t1Armed,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      b.anyRunnable == a.anyRunnable,
      b.pollActive == a.pollActive,
      not(b.faultCaught),
    },
    and {
      a.t2Status != "none",
      b.t2Cancel == true,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Armed == a.t2Armed,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      b.anyRunnable == a.anyRunnable,
      b.pollActive == a.pollActive,
      not(b.faultCaught),
    },
  }

  // Arm cancel ladder (second-press quit) strictly for the task matching owner.
  pure def armCancel(a: Abs, b: Abs): bool = or {
    and {
      a.t1Status == "ready",
      b.t1Armed == true,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      b.anyRunnable == a.anyRunnable,
      b.pollActive == a.pollActive,
      not(b.faultCaught),
    },
    and {
      a.t2Status == "ready",
      b.t2Armed == true,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      b.anyRunnable == a.anyRunnable,
      b.pollActive == a.pollActive,
      not(b.faultCaught),
    },
  }

  // Driver step: resume ready task under xpcall.
  // Completing or faulting task disarms its cancel ladder.
  pure def driverStep(a: Abs, b: Abs): bool = or {
    // Step slot 1
    and {
      a.t1Status == "ready",
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      or {
        // Normal yield
        and { b.t1Status == "ready", b.t1Armed == a.t1Armed, not(b.faultCaught) },
        // Normal finish: disarms
        and { b.t1Status == "done", not(b.t1Armed), not(b.faultCaught) },
        // Fault caught under xpcall: task retired, disarms, scheduler survives
        and { b.t1Status == "done", not(b.t1Armed), b.faultCaught == true },
      },
      b.anyRunnable == (b.t1Status == "ready" or b.t2Status == "ready"),
      b.pollActive == b.anyRunnable,
    },
    // Step slot 2
    and {
      a.t2Status == "ready",
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      or {
        // Normal yield
        and { b.t2Status == "ready", b.t2Armed == a.t2Armed, not(b.faultCaught) },
        // Normal finish: disarms
        and { b.t2Status == "done", not(b.t2Armed), not(b.faultCaught) },
        // Fault caught under xpcall: task retired, disarms, scheduler survives
        and { b.t2Status == "done", not(b.t2Armed), b.faultCaught == true },
      },
      b.anyRunnable == (b.t1Status == "ready" or b.t2Status == "ready"),
      b.pollActive == b.anyRunnable,
    },
  }

  // Retire finished task from table.
  pure def retire(a: Abs, b: Abs): bool = or {
    // Retire slot 1
    and {
      a.t1Status == "done",
      b.t1Status == "none",
      b.t1Owner == 0,
      not(b.t1Cancel),
      not(b.t1Armed),
      b.t2Status == a.t2Status,
      b.t2Owner == a.t2Owner,
      b.t2Cancel == a.t2Cancel,
      b.t2Armed == a.t2Armed,
      b.anyRunnable == (b.t2Status == "ready"),
      b.pollActive == b.anyRunnable,
      not(b.faultCaught),
    },
    // Retire slot 2
    and {
      a.t2Status == "done",
      b.t2Status == "none",
      b.t2Owner == 0,
      not(b.t2Cancel),
      not(b.t2Armed),
      b.t1Status == a.t1Status,
      b.t1Owner == a.t1Owner,
      b.t1Cancel == a.t1Cancel,
      b.t1Armed == a.t1Armed,
      b.anyRunnable == (b.t1Status == "ready"),
      b.pollActive == b.anyRunnable,
      not(b.faultCaught),
    },
  }

  pure def absNext(a: Abs, b: Abs): bool = or {
    a == b,
    spawn(a, b),
    requestCancel(a, b),
    armCancel(a, b),
    driverStep(a, b),
    retire(a, b),
  }

  // ---- properties every refining owner inherits ----

  // Cancel ladder is armed only while that specific task is ready (#636, #661).
  pure def ownershipIsolated(a: Abs): bool = and {
    a.t1Armed implies a.t1Status == "ready",
    a.t2Armed implies a.t2Status == "ready",
    (a.t1Status == "none") == (a.t1Owner == 0),
    (a.t2Status == "none") == (a.t2Owner == 0),
  }

  // Active poll cadence holds iff runnable work is pending (#637).
  pure def cadenceMatchesRunnable(a: Abs): bool =
    a.pollActive == a.anyRunnable

  // anyRunnable accurately reflects presence of ready tasks.
  pure def runnableConsistency(a: Abs): bool =
    a.anyRunnable == (a.t1Status == "ready" or a.t2Status == "ready")

  // Cancel can only be requested on a registered task.
  pure def cancelRequiresRegistered(a: Abs): bool = and {
    a.t1Cancel implies a.t1Status != "none",
    a.t2Cancel implies a.t2Status != "none",
  }

  pure def absInv(a: Abs): bool = and {
    ownershipIsolated(a),
    cadenceMatchesRunnable(a),
    runnableConsistency(a),
    cancelRequiresRegistered(a),
  }
}
