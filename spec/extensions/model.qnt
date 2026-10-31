// Model of fen's extension registry, event bus, and /reload, as it works today.
//
//   loader/init.fnl  load-module-spec!:
//       unregister-by-owner(owner)              <- FIRST, unconditionally
//       reload?: reload.clear-reload-modules!    <- raises on a module error,
//                                                   outside any pcall
//       pcall require entry; pcall register(api)
//       ok: record :loaded   fail: unregister-by-owner + record :error
//   loader/init.fnl  load!: loops specs in discovery order; no pcall per spec
//       around load-spec!, so a raise aborts the remaining specs.
//   loader/reload.fnl clear-reload-modules!: change-summary commits every
//       fingerprint BEFORE re-running modules; a failed module is restored to
//       its old package.loaded value.
//   register/*: singleton kinds (command, provider, auth/session backend) are
//       dicts, last writer wins; array kinds (tool, hook, control, prompt
//       fragment, bus subscription) append, so a re-registered owner moves to
//       the end. unregister-by-owner removes only records tagged with owner.
//   events.fnl emit: snapshot the bucket, then deliver to each snapshot entry
//       that is still in the live bucket.
//   inspectors/extensions extension tool, action=reload: runs
//       reload-extension! synchronously inside the running turn and replaces
//       state.agent; turn_submit keeps stepping the agent it captured, and
//       session_lifecycle only flushes :message-appended from state.agent.
//
// Two owners in discovery order A, B. A plays the sessions extension: it owns
// /reload. Both claim command "dup", a tool, a bus subscription, and a prompt
// fragment. FIXES names the candidate fixes enabled, by issue:
//   "624" transactional per-owner reload (failure keeps the previous
//         registrations as :stale and the pass continues)
//   "625" fingerprints committed only after a module reloads successfully
//   "626" registry views derived from per-owner sets folded in load order
//   "627" the `extension` tool's reload is deferred to the idle boundary
//   "628" register :tool validates :execute
module extensions {
  const FIXES: Set[str]

  pure val ORDER = ["A", "B"]
  pure val OWNERS = Set("A", "B")
  pure val NAMES = Set("dup", "reload", "bcmd")
  pure val SOURCES = Set("ok", "badModule", "badRegister")

  pure def cmdsOf(o: str): List[str] = if (o == "A") ["dup", "reload"] else ["dup", "bcmd"]

  // cmds: command name -> owner ("" = absent). tools/subs/frags: owner of each
  // array entry in bucket order.
  type Reg = { cmds: str -> str, tools: List[str], subs: List[str], frags: List[str] }

  pure val EMPTY: Reg = { cmds: NAMES.mapBy(_ => ""), tools: [], subs: [], frags: [] }

  pure def registerOwner(r: Reg, o: str): Reg = {
    cmds: cmdsOf(o).foldl(r.cmds, (m, n) => m.set(n, o)),
    tools: r.tools.append(o),
    subs: r.subs.append(o),
    frags: r.frags.append(o),
  }

  pure def unregisterOwner(r: Reg, o: str): Reg = {
    cmds: NAMES.mapBy(n => if (r.cmds.get(n) == o) "" else r.cmds.get(n)),
    tools: r.tools.select(x => x != o),
    subs: r.subs.select(x => x != o),
    frags: r.frags.select(x => x != o),
  }

  // What a fresh start produces for a set of working owners.
  pure def view(live: Set[str]): Reg =
    ORDER.foldl(EMPTY, (r, o) => if (live.contains(o)) registerOwner(r, o) else r)

  // status: "none" (no record) | "loaded" | "error" | "stale" (fixed: failed
  // reload, previous registrations kept) | "disabled"
  pure def serving(st: str -> str): Set[str] =
    OWNERS.filter(o => st.get(o) == "loaded" or st.get(o) == "stale")

  pure def listHas(l: List[str], x: str): bool = l.foldl(false, (b, y) => b or y == x)

  type Acc = {
    r: Reg, st: str -> str, fp: str -> bool, known: Set[str],
    visited: Set[str], aborted: bool, tried: str -> str,
  }

  // One owner through load-module-spec! with :reload? true.
  pure def reloadStep(srcs: str -> str, acc: Acc, o: str): Acc =
    if (acc.aborted) acc
    else
      val raw = srcs.get(o)
      // change-summary commits a fingerprint before the module runs; an
      // already-committed one skips the broken module, require returns the
      // restored old table, and registration succeeds (#625).
      val eff = if (raw == "badModule" and acc.fp.get(o)) "ok" else raw
      val fp2 = if (raw == "badModule" and not(FIXES.contains("625"))) acc.fp.set(o, true) else acc.fp
      val base = { ...acc, fp: fp2, visited: acc.visited.union(Set(o)), tried: acc.tried.set(o, raw) }
      // fixed (#626): every view is a fold of the serving owners in load order
      pure def regFor(st2: str -> str, mutated: Reg): Reg =
        if (FIXES.contains("626")) view(serving(st2)) else mutated
      if (eff == "ok")
        val st2 = acc.st.set(o, "loaded")
        { ...base, st: st2, r: regFor(st2, registerOwner(unregisterOwner(acc.r, o), o)),
          known: acc.known.union(Set(o)) }
      else if (FIXES.contains("624"))
        // fixed (#624): staged reload under pcall; on failure the previous
        // registrations stay, the owner is :stale (or :error if it never
        // served), and the pass goes on.
        val st2 = acc.st.set(o, if (serving(acc.st).contains(o)) "stale" else "error")
        { ...base, st: st2, r: regFor(st2, acc.r) }
      else if (eff == "badRegister")
        val st2 = acc.st.set(o, "error")
        { ...base, st: st2, r: regFor(st2, unregisterOwner(acc.r, o)) }
      else
        // clear-reload-modules! raised: unregister-by-owner also dropped the
        // state.extensions record; the raise escapes load!.
        val st2 = acc.st.set(o, "none")
        { ...base, st: st2, r: regFor(st2, unregisterOwner(acc.r, o)), aborted: true }

  // ---- state ----
  var src: str -> str          // source on disk per owner
  var fpCommitted: str -> bool // broken module's fingerprint already committed
  var reg: Reg
  var status: str -> str
  var known: Set[str]          // loader `loaded` table (eligible for reload-extension!)
  var tried: str -> str        // ghost: source seen by the last load attempt
  var visited: Set[str]        // ghost: owners attempted by the last /reload pass
  var passDone: bool           // ghost: last action was a full /reload
  var phase: str               // "idle" | "busy"
  var agentId: int             // identity of state.agent
  var turnAgent: int           // agent the running turn captured
  var turnTools: List[str]     // agent.tools snapshot taken at make-agent
  var unflushed: int           // messages appended but not persisted
  var pending: List[str]       // fixed: deferred extension reload requests
  var busOk: bool              // ghost: every delivery was to a live subscriber, once
  var malformed: bool          // ghost: a callable-less record was registered
  var lastAction: str

  pure def acc0(st: str -> str, fp: str -> bool, r: Reg, k: Set[str], t: str -> str): Acc =
    { r: r, st: st, fp: fp, known: k, visited: Set(), aborted: false, tried: t }

  action init = all {
    src' = OWNERS.mapBy(_ => "ok"),
    fpCommitted' = OWNERS.mapBy(_ => false),
    reg' = view(OWNERS),
    status' = OWNERS.mapBy(_ => "loaded"),
    known' = OWNERS,
    tried' = OWNERS.mapBy(_ => "ok"),
    visited' = Set(), passDone' = false,
    phase' = "idle", agentId' = 0, turnAgent' = 0, turnTools' = [],
    unflushed' = 0, pending' = [], busOk' = true, malformed' = false,
    lastAction' = "init",
  }

  // Apply one reload pass result.
  action applyAcc(a: Acc, full: bool, agentBump: bool, name: str): bool = all {
    reg' = a.r, status' = a.st, fpCommitted' = a.fp, known' = a.known,
    tried' = a.tried,
    visited' = if (full) a.visited else visited,
    passDone' = full,
    agentId' = if (agentBump) agentId + 1 else agentId,
    lastAction' = name,
  }

  // The developer edits an extension's source; its fingerprint changes.
  action edit(o: str, v: str): bool = all {
    src.get(o) != v,
    src' = src.set(o, v),
    fpCommitted' = fpCommitted.set(o, false),
    reg' = reg, status' = status, known' = known, tried' = tried,
    visited' = visited, passDone' = false, phase' = phase, agentId' = agentId,
    turnAgent' = turnAgent, turnTools' = turnTools, unflushed' = unflushed,
    pending' = pending, busOk' = busOk, malformed' = malformed,
    lastAction' = "edit",
  }

  // /reload (idle-only, dispatched by name, so it needs the command).
  action reloadAll = all {
    phase == "idle",
    reg.cmds.get("reload") != "",
    val a = ORDER.foldl(acc0(status, fpCommitted, reg, known, tried),
                        (acc, o) => reloadStep(src, acc, o))
    applyAcc(a, true, false, "reloadAll"),
    src' = src, phase' = phase, turnAgent' = turnAgent, turnTools' = turnTools,
    unflushed' = unflushed, pending' = pending, busOk' = busOk, malformed' = malformed,
  }

  // /reload-extension <o> at idle.
  action reloadOne(o: str): bool = all {
    phase == "idle",
    known.contains(o),
    val a = reloadStep(src, acc0(status, fpCommitted, reg, known, tried), o)
    applyAcc(a, false, not(a.aborted) and a.st.get(o) == "loaded", "reloadOne"),
    src' = src, phase' = phase, turnAgent' = turnAgent, turnTools' = turnTools,
    unflushed' = unflushed, pending' = pending, busOk' = busOk, malformed' = malformed,
  }

  action startTurn = all {
    phase == "idle",
    phase' = "busy", turnAgent' = agentId, turnTools' = reg.tools,
    src' = src, fpCommitted' = fpCommitted, reg' = reg, status' = status,
    known' = known, tried' = tried, visited' = visited, passDone' = false,
    agentId' = agentId, unflushed' = unflushed, pending' = pending,
    busOk' = busOk, malformed' = malformed, lastAction' = "startTurn",
  }

  // The model calls the `extension` tool with action=reload mid-turn.
  action midTurnReload(o: str): bool = all {
    phase == "busy",
    known.contains(o),
    if (FIXES.contains("627"))
      all {
        pending' = pending.append(o),
        src' = src, fpCommitted' = fpCommitted, reg' = reg, status' = status,
        known' = known, tried' = tried, visited' = visited, passDone' = false,
        agentId' = agentId, lastAction' = "midTurnReload(deferred)",
      }
    else
      val a = reloadStep(src, acc0(status, fpCommitted, reg, known, tried), o)
      all {
        // perform-extension-reload! rebuilds state.agent only on success.
        applyAcc(a, false, not(a.aborted) and a.st.get(o) == "loaded", "midTurnReload"),
        src' = src, pending' = pending,
      },
    phase' = phase, turnAgent' = turnAgent, turnTools' = turnTools,
    unflushed' = unflushed, busOk' = busOk, malformed' = malformed,
  }

  // The running turn appends a message (tool result / assistant reply).
  action turnAppend = all {
    phase == "busy", unflushed < 3,
    // session_lifecycle flushes only when ev.agent == state.agent; a flush
    // writes every pending message.
    unflushed' = if (turnAgent == agentId) 0 else unflushed + 1,
    src' = src, fpCommitted' = fpCommitted, reg' = reg, status' = status,
    known' = known, tried' = tried, visited' = visited, passDone' = false,
    phase' = phase, agentId' = agentId, turnAgent' = turnAgent,
    turnTools' = turnTools, pending' = pending, busOk' = busOk,
    malformed' = malformed, lastAction' = "turnAppend",
  }

  action endTurn = all {
    phase == "busy",
    phase' = "idle",
    src' = src, fpCommitted' = fpCommitted, reg' = reg, status' = status,
    known' = known, tried' = tried, visited' = visited, passDone' = false,
    agentId' = agentId, turnAgent' = turnAgent, turnTools' = turnTools,
    unflushed' = unflushed, pending' = pending, busOk' = busOk,
    malformed' = malformed, lastAction' = "endTurn",
  }

  // Fixed: a deferred reload runs at the idle boundary, then the agent is rebuilt.
  action drainPending = all {
    phase == "idle", pending.length() > 0,
    val o = pending[0]
    val a = reloadStep(src, acc0(status, fpCommitted, reg, known, tried), o)
    applyAcc(a, false, true, "drainPending"),
    pending' = pending.slice(1, pending.length()),
    src' = src, phase' = phase, turnAgent' = turnAgent, turnTools' = turnTools,
    unflushed' = unflushed, busOk' = busOk, malformed' = malformed,
  }

  // Emit one event. Optionally (at idle, like the idle-only commands that
  // disable extensions) the first handler to run unloads owner B
  // (unregister-by-owner) before the rest of the snapshot is dispatched.
  action emit(unloadB: bool): bool = all {
    not(unloadB) or phase == "idle",
    val snapshot = reg.subs
    val res = snapshot.foldl({ live: snapshot, out: [], ok: true },
      (acc, o) =>
        if (listHas(acc.live, o))
          val live2 = if (unloadB and acc.out.length() == 0) acc.live.select(x => x != "B") else acc.live
          { live: live2, out: acc.out.append(o), ok: acc.ok and not(listHas(acc.out, o)) }
        else acc)
    val st2 = if (unloadB and snapshot.length() > 0) status.set("B", "disabled") else status
    val r2 =
      if (unloadB and snapshot.length() > 0)
        (if (FIXES.contains("626")) view(serving(st2)) else unregisterOwner(reg, "B"))
      else reg
    all {
      busOk' = (busOk and res.ok),
      reg' = r2, status' = st2,
      src' = src, fpCommitted' = fpCommitted, known' = known, tried' = tried,
      visited' = visited, passDone' = false, phase' = phase, agentId' = agentId,
      turnAgent' = turnAgent, turnTools' = turnTools, unflushed' = unflushed,
      pending' = pending, malformed' = malformed,
      lastAction' = if (unloadB) "emit(unloadB)" else "emit",
    }
  }

  // An extension registers a contribution missing its callable.
  pure def validatesCallable(kind: str): bool = FIXES.contains("628") or kind != "tool"

  action registerMalformed(kind: str): bool = all {
    not(validatesCallable(kind)),
    malformed' = true,
    src' = src, fpCommitted' = fpCommitted, reg' = reg, status' = status,
    known' = known, tried' = tried, visited' = visited, passDone' = false,
    phase' = phase, agentId' = agentId, turnAgent' = turnAgent,
    turnTools' = turnTools, unflushed' = unflushed, pending' = pending,
    busOk' = busOk, lastAction' = "registerMalformed",
  }

  action step = any {
    nondet o = OWNERS.oneOf()
    nondet v = SOURCES.oneOf()
    edit(o, v),
    reloadAll,
    nondet o = OWNERS.oneOf()
    reloadOne(o),
    startTurn,
    nondet o = OWNERS.oneOf()
    midTurnReload(o),
    turnAppend,
    endTurn,
    drainPending,
    nondet u = Set(true, false).oneOf()
    emit(u),
    nondet k = Set("tool", "command", "hook").oneOf()
    registerMalformed(k),
  }

  // ---- properties ----

  // The registry is exactly what a fresh start of the working owners gives:
  // no leaked or duplicated entries, collisions resolved by load order.
  val registryMatchesFreshStart = reg == view(serving(status))

  // A /reload pass attempts every extension.
  val reloadVisitsEveryOwner = passDone implies visited == OWNERS

  // An extension that was loaded keeps a status record (/extensions shows it).
  val attemptedOwnerListed = known.forall(o => status.get(o) != "none")

  // The recovery command survives any reload.
  val reloadCommandAvailable = reg.cmds.get("reload") != ""

  // :loaded never hides a broken source seen by the last attempt.
  val loadedStatusTruthful =
    OWNERS.forall(o => status.get(o) == "loaded" implies tried.get(o) == "ok")

  // Each event reaches each live subscriber at most once, never a removed one.
  val busDeliversOncePerLiveSubscriber = busOk

  // Modules and registrations never swap under a running turn.
  val noRegistrySwapDuringTurn = phase == "busy" implies agentId == turnAgent

  // Every tool the running turn can call still has a registered owner.
  val turnToolsLive =
    phase == "busy" implies turnTools.foldl(true, (b, o) => b and listHas(reg.tools, o))

  // Messages appended by a finished turn are persisted.
  val turnMessagesPersisted = phase == "idle" implies unflushed == 0

  // Register-kind validation rejects records without their callable.
  val registeredCallablesPresent = not(malformed)

  val allInvariants = and {
    registryMatchesFreshStart, reloadVisitsEveryOwner, attemptedOwnerListed,
    reloadCommandAvailable, loadedStatusTruthful, busDeliversOncePerLiveSubscriber,
    noRegistrySwapDuringTurn, turnToolsLive, turnMessagesPersisted,
    registeredCallablesPresent,
  }
}

module current { import extensions(FIXES = Set("624", "625", "626", "627", "628")).* }
module fixed { import extensions(FIXES = Set("624", "625", "626", "627", "628")).* }
module fix624 { import extensions(FIXES = Set("624")).* }
module fix625 { import extensions(FIXES = Set("625")).* }
module fix626 { import extensions(FIXES = Set("626")).* }
module fix627 { import extensions(FIXES = Set("627")).* }
module fix628 { import extensions(FIXES = Set("628")).* }
