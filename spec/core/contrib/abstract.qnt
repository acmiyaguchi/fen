// Abstract specification of extension contribution map (#673):
// per-owner contribution map swapped atomically when idle.
//
// The registry is a pure function of load order and the serving owners
// (fresh-start semantics). A failed reload rolls back to the previous
// working contributions (marking the owner stale while keeping it serving).
// While a turn is running, no contribution swaps take place: reloads requested
// mid-turn are deferred and swapped atomically at the idle boundary.
//
// Pure definitions only, so concrete models can import them.
module contribAbstract {
  // Registry view: shared command duplicate winner (last writer wins),
  // reload command owner, bcmd owner, bucket order.
  type Reg = { dup: str, reload: str, bcmd: str, order: str }

  pure val EMPTY_REG: Reg = { dup: "", reload: "", bcmd: "", order: "" }

  // Discovery / load order: A then B.
  pure def view(servesA: bool, servesB: bool): Reg =
    if (servesA and servesB)
      { dup: "B", reload: "A", bcmd: "B", order: "AB" }
    else if (servesA)
      { dup: "A", reload: "A", bcmd: "", order: "A" }
    else if (servesB)
      { dup: "B", reload: "", bcmd: "B", order: "B" }
    else
      EMPTY_REG

  pure def serves(st: str): bool = st == "loaded" or st == "stale"

  type Abs = {
    phase: str,        // "idle" | "busy"
    stA: str,          // "loaded" | "stale" (A owns recovery and always serves)
    stB: str,          // "loaded" | "stale" | "error" | "disabled"
    reg: Reg,          // active registry view == view(serves(stA), serves(stB))
    snap: Reg,         // turn snapshot (equals reg during busy)
    pending: bool,     // reload requested mid-turn, deferred to idle boundary
  }

  pure val absInit: Abs = {
    phase: "idle",
    stA: "loaded",
    stB: "loaded",
    reg: view(true, true),
    snap: view(true, true),
    pending: false,
  }

  // A turn starts: captures the active registry into snap.
  pure def turnStart(a: Abs, b: Abs): bool = and {
    a.phase == "idle",
    b.phase == "busy",
    b.stA == a.stA,
    b.stB == a.stB,
    b.reg == a.reg,
    b.snap == a.reg,
    b.pending == a.pending,
  }

  // A turn ends: transitions to idle.
  pure def turnEnd(a: Abs, b: Abs): bool = and {
    a.phase == "busy",
    b.phase == "idle",
    b.stA == a.stA,
    b.stB == a.stB,
    b.reg == a.reg,
    b.snap == a.snap,
    b.pending == a.pending,
  }

  // Reload one owner when idle: swaps atomically.
  // Success -> loaded; Failure with rollback -> stale if was serving, else error.
  pure def reloadIdle(a: Abs, b: Abs, owner: str, success: bool): bool = and {
    a.phase == "idle",
    val nextStA =
      if (owner == "A") (if (success) "loaded" else (if (serves(a.stA)) "stale" else "error"))
      else a.stA
    val nextStB =
      if (owner == "B") (if (success) "loaded" else (if (serves(a.stB)) "stale" else "error"))
      else a.stB
    and {
      b.phase == "idle",
      b.stA == nextStA,
      b.stB == nextStB,
      b.reg == view(serves(nextStA), serves(nextStB)),
      b.snap == b.reg,
      b.pending == a.pending,
    },
  }

  // Request a reload during a busy turn: deferred, registry not swapped.
  pure def requestMidTurn(a: Abs, b: Abs): bool = and {
    a.phase == "busy",
    b.phase == "busy",
    b.stA == a.stA,
    b.stB == a.stB,
    b.reg == a.reg,
    b.snap == a.snap,
    b.pending,
  }

  // Drain deferred reload at idle boundary: swaps atomically.
  pure def drainPending(a: Abs, b: Abs, successA: bool, successB: bool): bool = and {
    a.phase == "idle",
    a.pending,
    val nextStA = if (successA) "loaded" else (if (serves(a.stA)) "stale" else "error")
    val nextStB = if (successB) "loaded" else (if (serves(a.stB)) "stale" else "error")
    and {
      b.phase == "idle",
      b.stA == nextStA,
      b.stB == nextStB,
      b.reg == view(serves(nextStA), serves(nextStB)),
      b.snap == b.reg,
      not(b.pending),
    },
  }

  // Disable extension B when idle: swaps atomically.
  pure def disableB(a: Abs, b: Abs): bool = and {
    a.phase == "idle",
    serves(a.stB),
    b.phase == "idle",
    b.stA == a.stA,
    b.stB == "disabled",
    b.reg == view(serves(a.stA), false),
    b.snap == b.reg,
    b.pending == a.pending,
  }

  pure def absNext(a: Abs, b: Abs): bool = or {
    a == b,
    turnStart(a, b),
    turnEnd(a, b),
    reloadIdle(a, b, "A", true),
    reloadIdle(a, b, "A", false),
    reloadIdle(a, b, "B", true),
    reloadIdle(a, b, "B", false),
    requestMidTurn(a, b),
    drainPending(a, b, true, true),
    drainPending(a, b, true, false),
    drainPending(a, b, false, true),
    drainPending(a, b, false, false),
    disableB(a, b),
  }

  // ---- properties ----

  // Active registry matches the fresh-start view of serving owners.
  pure def registryMatchesFreshStart(a: Abs): bool =
    a.reg == view(serves(a.stA), serves(a.stB))

  // While a turn is running, the active registry is identical to the snapshot taken at turn start.
  pure def noSwapDuringTurn(a: Abs): bool =
    a.phase == "busy" implies a.reg == a.snap

  // The recovery command is always available as long as A serves.
  pure def reloadCommandAvailable(a: Abs): bool =
    serves(a.stA) implies a.reg.reload == "A"

  // Serving status of A is preserved (A never disabled or dropped).
  pure def coreOwnerServing(a: Abs): bool =
    serves(a.stA)

  pure def absInv(a: Abs): bool = and {
    registryMatchesFreshStart(a),
    noSwapDuringTurn(a),
    reloadCommandAvailable(a),
    coreOwnerServing(a),
  }
}
