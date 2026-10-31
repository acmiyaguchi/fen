// Proof model: a running turn keeps the agent and tools it started with (#627).
//
// Contract: modules and registrations swap only at an idle boundary, so the
// turn's agent is state.agent for its whole life, every tool in its snapshot
// stays registered, and every message it appends is flushed.
//
// Only the state the contract needs: turn phase, whether state.agent is still
// the agent the running turn captured, B's source and whether B's tool is
// registered, whether the turn's tool snapshot holds B's tool, whether an
// appended message is unflushed, and the deferred reload request.
//
// Integration model: ../../model.qnt.
module turnIdentity {
  const FIXES: Set[str]

  var phase: str        // "idle" | "busy"
  var swapped: bool     // state.agent is not the agent the running turn steps
  var srcB: str         // "ok" | "bad"
  var bTool: bool       // B's tool is registered
  var snapB: bool       // the running turn's agent.tools snapshot holds B's tool
  var unflushed: bool   // a message was appended and not persisted
  var pending: bool     // a deferred `extension` reload of B is queued

  action init = all {
    phase' = "idle", swapped' = false, srcB' = "ok", bTool' = true, snapB' = false,
    unflushed' = false, pending' = false,
  }

  action edit(v: str): bool = all {
    srcB != v, srcB' = v,
    phase' = phase, swapped' = swapped, bTool' = bTool, snapB' = snapB,
    unflushed' = unflushed, pending' = pending,
  }

  // turn_submit captures state.agent; make-agent snapshots the tools.
  action startTurn = all {
    phase == "idle",
    phase' = "busy", swapped' = false, snapB' = bTool,
    srcB' = srcB, bTool' = bTool, unflushed' = unflushed, pending' = pending,
  }

  // reload-extension! B: unregister first; re-register on success, and
  // perform-extension-reload! rebuilds state.agent only then.
  action midTurnReload = all {
    phase == "busy",
    if (FIXES.contains("627"))
      all { pending' = true, swapped' = swapped, bTool' = bTool }
    else
      all { pending' = pending, bTool' = (srcB == "ok"), swapped' = (swapped or srcB == "ok") },
    phase' = phase, srcB' = srcB, snapB' = snapB, unflushed' = unflushed,
  }

  // session_lifecycle flushes only when ev.agent == state.agent.
  action turnAppend = all {
    phase == "busy",
    unflushed' = (swapped),
    phase' = phase, swapped' = swapped, srcB' = srcB, bTool' = bTool, snapB' = snapB,
    pending' = pending,
  }

  action endTurn = all {
    phase == "busy",
    phase' = "idle",
    swapped' = swapped, srcB' = srcB, bTool' = bTool, snapB' = snapB,
    unflushed' = unflushed, pending' = pending,
  }

  // fixed: the deferred reload runs at the idle boundary.
  action drainPending = all {
    phase == "idle", pending,
    pending' = false, bTool' = (srcB == "ok"),
    phase' = phase, swapped' = swapped, srcB' = srcB, snapB' = snapB,
    unflushed' = unflushed,
  }

  action step = any {
    nondet v = Set("ok", "bad").oneOf()
    edit(v),
    startTurn, midTurnReload, turnAppend, endTurn, drainPending,
  }

  val noRegistrySwapDuringTurn = phase == "busy" implies not(swapped)
  val turnToolsLive = (phase == "busy" and snapB) implies bTool
  val turnMessagesPersisted = phase == "idle" implies not(unflushed)

  val turnIdentityInductive = and {
    phase.in(Set("idle", "busy")), swapped.in(Bool), srcB.in(Set("ok", "bad")),
    bTool.in(Bool), snapB.in(Bool), unflushed.in(Bool), pending.in(Bool),
    not(unflushed),
    noRegistrySwapDuringTurn, turnToolsLive, turnMessagesPersisted,
  }
}

module current { import turnIdentity(FIXES = Set("627")).* }
module fixed { import turnIdentity(FIXES = Set("627")).* }
