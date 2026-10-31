// Model of fen session persistence and replay, as it works today.
//
//   agent.append-message!  -> :message-appended
//   session_lifecycle      -> flush closure: once any assistant (incl. :aborted)
//                             exists, append mem[saved+1..] one by one; the
//                             cursor advances whether or not append succeeded
//   jsonl append-entry     -> one `json .. "\n"` write to an :a handle; a failed
//                             write logs and returns nil; a partial last line
//                             left by a killed process is NOT terminated first,
//                             so the next write lands on the same line
//   jsonl load             -> skip malformed lines; latest compaction whose
//                             first-kept-entry-id resolves => [summary] ++
//                             messages from that entry; no tool-pair repair
//   compact                -> flush; require first-kept entry id; append
//                             :compaction; replace agent.messages; new flush
//                             cursor = #messages. Runs idle (/compact, auto) or
//                             mid-turn as the `compact` tool.
//   agent cancel           -> synthetic results for unreturned calls, then an
//                             empty :aborted assistant (filtered from context)
//   interactive --continue -> load + open-existing; takes NO session lock
//   fen session send       -> acquire-lock, load-strict, one turn, release
//   session doctor         -> pairing by id set (not adjacency); repair drops
//                             malformed lines and orphan results, inserts a
//                             marker result after each never-answered call
//
// Entry ids are message ids (`mid`); one tool call per assistant is enough.
// FIXED selects the candidate fixes so the same invariants can be checked.
module sessions {
  const FIXED: bool
  // Whether a second process (`fen session send`) may touch the session.
  const OTHER_WRITER: bool

  pure val MAX_MID = 12

  // role: user | asst | call (assistant with one tool call, call == mid) |
  //       result | aborted | summary (synthetic, from a compaction entry)
  type Msg = { mid: int, role: str, call: int }
  // kind: msg | compaction | garbage (malformed / torn JSONL line)
  type Line = { kind: str, msg: Msg, keep: int }

  pure val NOMSG: Msg = { mid: -1, role: "none", call: -1 }
  pure val GARBAGE: Line = { kind: "garbage", msg: NOMSG, keep: -1 }
  pure val SUMMARY: Msg = { mid: 0, role: "summary", call: -1 }
  pure val NOINTS: Set[int] = Set()
  pure val NOMSGS: List[Msg] = []
  pure val NOLINES: List[Line] = []

  pure def msgLine(m: Msg): Line = { kind: "msg", msg: m, keep: -1 }
  // Synthetic "interrupted" result for call c (repair marker).
  pure def synth(c: int): Msg = { mid: 100 + c, role: "result", call: c }

  pure def isAssistant(m: Msg): bool =
    m.role == "asst" or m.role == "call" or m.role == "aborted"
  pure def assistantPresent(ms: List[Msg]): bool =
    ms.foldl(false, (a, m) => a or isAssistant(m))

  // ---- replay (jsonl load) ----
  pure def msgsOf(disk: List[Line]): List[Msg] =
    disk.foldl(NOMSGS, (acc, l) => if (l.kind == "msg") acc.append(l.msg) else acc)

  pure def midsOf(disk: List[Line]): Set[int] =
    msgsOf(disk).foldl(NOINTS, (s, m) => s.union(Set(m.mid)))

  pure def indexOfMid(ms: List[Msg], mid: int): int =
    range(0, ms.length()).foldl(-1, (acc, i) => if (acc < 0 and ms[i].mid == mid) i else acc)

  // latest-valid-compaction: index of the first kept message, or -1.
  pure def compactionIndex(disk: List[Line]): int =
    val ms = msgsOf(disk)
    disk.foldl(-1, (acc, l) =>
      if (l.kind == "compaction" and indexOfMid(ms, l.keep) >= 0) indexOfMid(ms, l.keep)
      else acc)

  pure def replayRaw(disk: List[Line]): List[Msg] =
    val ms = msgsOf(disk)
    val k = compactionIndex(disk)
    if (k >= 0) [SUMMARY].concat(ms.slice(k, ms.length())) else ms

  // Candidate fix: provider-neutral repair at replay time (what the OpenAI
  // converters already do privately): a call not immediately answered gets a
  // synthetic interrupted result.
  pure def repairDangling(ms: List[Msg]): List[Msg] =
    val r = ms.foldl({ out: NOMSGS, open: -1 }, (st, m) =>
      val answered = m.role == "result" and m.call == st.open
      val out1 = if (st.open >= 0 and not(answered)) st.out.append(synth(st.open)) else st.out
      { out: out1.append(m), open: if (m.role == "call") m.call else -1 })
    if (r.open >= 0) r.out.append(synth(r.open)) else r.out

  pure def replay(disk: List[Line]): List[Msg] =
    if (FIXED) repairDangling(replayRaw(disk)) else replayRaw(disk)

  // Anthropic-shaped validity (no converter-side repair): every tool call is
  // immediately followed by its result and every result immediately follows
  // its call. :aborted markers are dropped by build-context.
  pure def contextValid(ms: List[Msg]): bool =
    val c = ms.select(m => m.role != "aborted")
    c.indices().forall(i =>
      (if (c[i].role == "call")
         (if (i + 1 < c.length()) c[i + 1].role == "result" and c[i + 1].call == c[i].call
          else false)
       else true)
      and
      (if (c[i].role == "result")
         (if (i > 0) c[i - 1].role == "call" and c[i - 1].call == c[i].call else false)
       else true))

  // ---- session doctor ----
  // Today: pending set keyed by call id; order between call and result ignored.
  pure def doctorIssuesById(disk: List[Line]): int =
    val st = disk.foldl({ issues: 0, pending: NOINTS }, (s, l) =>
      if (l.kind == "garbage") { ...s, issues: s.issues + 1 }
      else if (l.kind != "msg") s
      else if (l.msg.role == "call") { ...s, pending: s.pending.union(Set(l.msg.call)) }
      else if (l.msg.role == "result")
        (if (s.pending.contains(l.msg.call)) { ...s, pending: s.pending.exclude(Set(l.msg.call)) }
         else { ...s, issues: s.issues + 1 })
      else s)
    st.issues + st.pending.size()

  pure def doctorRepairById(disk: List[Line]): List[Line] =
    val st = disk.foldl({ out: NOLINES, pending: NOINTS }, (s, l) =>
      if (l.kind == "garbage") s
      else if (l.kind == "msg" and l.msg.role == "call")
        { out: s.out.append(l), pending: s.pending.union(Set(l.msg.call)) }
      else if (l.kind == "msg" and l.msg.role == "result")
        (if (s.pending.contains(l.msg.call))
           { out: s.out.append(l), pending: s.pending.exclude(Set(l.msg.call)) }
         else s)
      else { ...s, out: s.out.append(l) })
    st.out.foldl(NOLINES, (acc, l) =>
      if (l.kind == "msg" and l.msg.role == "call" and st.pending.contains(l.msg.call))
        acc.append(l).append(msgLine(synth(l.msg.call)))
      else acc.append(l))

  // Candidate fix: adjacency over message entries (compaction entries skipped).
  pure def doctorIssuesAdj(disk: List[Line]): int =
    val st = disk.foldl({ issues: 0, open: -1 }, (s, l) =>
      if (l.kind == "garbage") { ...s, issues: s.issues + 1 }
      else if (l.kind != "msg") s
      else
        val answered = l.msg.role == "result" and l.msg.call == s.open
        val i1 = if (s.open >= 0 and not(answered)) s.issues + 1 else s.issues
        val i2 = if (l.msg.role == "result" and not(answered)) i1 + 1 else i1
        { issues: i2, open: if (l.msg.role == "call") l.msg.call else -1 })
    st.issues + (if (st.open >= 0) 1 else 0)

  pure def doctorRepairAdj(disk: List[Line]): List[Line] =
    val st = disk.foldl({ out: NOLINES, open: -1 }, (s, l) =>
      if (l.kind == "garbage") s
      else if (l.kind != "msg") { ...s, out: s.out.append(l) }
      else
        val answered = l.msg.role == "result" and l.msg.call == s.open
        val out1 = if (s.open >= 0 and not(answered)) s.out.append(msgLine(synth(s.open))) else s.out
        if (l.msg.role == "result" and not(answered)) { out: out1, open: -1 }
        else { out: out1.append(l), open: if (l.msg.role == "call") l.msg.call else -1 })
    if (st.open >= 0) st.out.append(msgLine(synth(st.open))) else st.out

  pure def doctorIssues(disk: List[Line]): int =
    if (FIXED) doctorIssuesAdj(disk) else doctorIssuesById(disk)
  pure def doctorRepair(disk: List[Line]): List[Line] =
    if (FIXED) doctorRepairAdj(disk) else doctorRepairById(disk)

  // ---- writer: append-entry + flush closure ----
  type FS = { disk: List[Line], torn: bool, saved: int, persisted: Set[int],
              acked: Set[int], fail: bool, stopped: bool }

  // Today a torn tail swallows the next line. FIXED terminates it on open.
  pure def appendLine(disk: List[Line], torn: bool, l: Line): { disk: List[Line], torn: bool } =
    if (torn) { disk: disk.replaceAt(disk.length() - 1, GARBAGE), torn: false }
    else { disk: disk.append(l), torn: false }

  pure def flushStep(s: FS, m: Msg): FS =
    if (s.stopped) s
    else if (s.fail)
      // write error (ENOSPC, EIO, unopenable dir): append returns nil
      if (FIXED) { ...s, fail: false, stopped: true }
      else { ...s, fail: false, saved: s.saved + 1, acked: s.acked.union(Set(m.mid)) }
    else
      val w = appendLine(s.disk, s.torn, msgLine(m))
      { ...s, disk: w.disk, torn: w.torn, saved: s.saved + 1,
        persisted: s.persisted.union(Set(m.mid)), acked: s.acked.union(Set(m.mid)) }

  pure def flush(s: FS, mem: List[Msg]): FS =
    if (not(assistantPresent(mem))) s
    else range(s.saved, mem.length()).foldl({ ...s, stopped: false }, (acc, i) => flushStep(acc, mem[i]))

  // ---- state ----
  var up: bool              // interactive process A alive
  var phase: str            // idle | llm (provider call pending) | tools (result pending)
  var mem: List[Msg]        // agent.messages
  var saved: int            // flush cursor (last-saved)
  var pendingCall: int
  var disk: List[Line]      // JSONL entries (header elided)
  var torn: bool            // last line is partial (no trailing newline)
  var persisted: Set[int]   // mids carrying __session-entry-id
  var acked: Set[int]       // mids a writer considered saved (ghost)
  var failNext: bool        // next write fails (environment)
  var nextMid: int
  var bContextOk: bool      // every `session send` provider call had valid context (ghost)
  var lastAction: str

  val curFS: FS = { disk: disk, torn: torn, saved: saved, persisted: persisted,
                    acked: acked, fail: failNext, stopped: false }

  action init = all {
    up' = true, phase' = "idle", mem' = [], saved' = 0, pendingCall' = -1,
    disk' = [], torn' = false, persisted' = Set(), acked' = Set(),
    failNext' = false, nextMid' = 1, bContextOk' = true, lastAction' = "init",
  }

  // Append messages to agent.messages; :message-appended flushes.
  action appendAndFlush(newMem: List[Msg], newPhase: str, newPending: int,
                        newNext: int, act: str): bool =
    val fs = flush(curFS, newMem)
    all {
      mem' = newMem, phase' = newPhase, pendingCall' = newPending, nextMid' = newNext,
      disk' = fs.disk, torn' = fs.torn, saved' = fs.saved, persisted' = fs.persisted,
      acked' = fs.acked, failNext' = fs.fail, up' = up, bContextOk' = bContextOk,
      lastAction' = act,
    }

  action userPrompt = all {
    up, phase == "idle", nextMid <= MAX_MID,
    appendAndFlush(mem.append({ mid: nextMid, role: "user", call: -1 }), "llm", -1,
                   nextMid + 1, "userPrompt"),
  }

  action assistant(toolCall: bool): bool = all {
    up, phase == "llm", nextMid <= MAX_MID,
    if (toolCall)
      appendAndFlush(mem.append({ mid: nextMid, role: "call", call: nextMid }), "tools",
                     nextMid, nextMid + 1, "assistantCall")
    else
      appendAndFlush(mem.append({ mid: nextMid, role: "asst", call: -1 }), "idle", -1,
                     nextMid + 1, "assistantText"),
  }

  action toolResult = all {
    up, phase == "tools", nextMid <= MAX_MID,
    appendAndFlush(mem.append({ mid: nextMid, role: "result", call: pendingCall }), "llm",
                   -1, nextMid + 1, "toolResult"),
  }

  // Ctrl-C at a yield: pair the unreturned call, then the :aborted marker.
  action cancel = all {
    up, phase == "llm" or phase == "tools", nextMid + 1 <= MAX_MID,
    val withResult =
      if (phase == "tools") mem.append({ mid: nextMid, role: "result", call: pendingCall })
      else mem
    appendAndFlush(withResult.append({ mid: nextMid + 1, role: "aborted", call: -1 }), "idle",
                   -1, nextMid + 2, "cancel"),
  }

  // /compact, auto-compaction (idle) or the `compact` tool (mid-turn, before
  // its own result). The cut is any user message after index 0, which
  // over-approximates find-cut-point's token-budget choice.
  pure def roleAt(ms: List[Msg], i: int): str =
    if (i >= 0 and i < ms.length()) ms[i].role else "none"
  pure def midAt(ms: List[Msg], i: int): int =
    if (i >= 0 and i < ms.length()) ms[i].mid else -1

  action compact(cut: int): bool = all {
    up, phase == "idle" or phase == "tools",
    cut >= 1, roleAt(mem, cut) == "user",
    val fs = flush(curFS, mem)
    val firstKept = midAt(mem, cut)
    // FIXED: every kept message must be persisted, not only the first.
    val idsOk = fs.persisted.contains(firstKept) and (not(FIXED) or fs.saved == mem.length())
    val w = appendLine(fs.disk, fs.torn, { kind: "compaction", msg: NOMSG, keep: firstKept })
    val newMem = [SUMMARY].concat(mem.slice(cut, mem.length()))
    // validation error, or append-entry failed: no replace
    val ok = idsOk and not(fs.fail)
    all {
      mem' = if (ok) newMem else mem,
      phase' = phase, pendingCall' = pendingCall, nextMid' = nextMid,
      disk' = if (ok) w.disk else fs.disk,
      torn' = if (ok) w.torn else fs.torn,
      saved' = if (ok) newMem.length() else fs.saved,
      persisted' = fs.persisted, acked' = fs.acked, failNext' = false, up' = up,
      bContextOk' = bContextOk, lastAction' = if (ok) "compact" else "compactFailed",
    },
  }

  // Process killed at any point; with tornWrite it dies inside a large
  // write (stdio splits long lines into several write(2) calls).
  action crash(tornWrite: bool): bool = all {
    up,
    not(tornWrite) or (phase != "idle" and disk.length() > 0 and not(torn)),
    up' = false, phase' = "idle", mem' = [], saved' = 0, pendingCall' = -1,
    disk' = if (tornWrite) disk.append(GARBAGE) else disk,
    torn' = (tornWrite or torn),
    persisted' = persisted, acked' = acked, failNext' = failNext, nextMid' = nextMid,
    bContextOk' = bContextOk, lastAction' = if (tornWrite) "crashTorn" else "crash",
  }

  // fen --continue (start!): load, open-existing, flush cursor = #replayed.
  action resume = all {
    not(up),
    val m = replay(disk)
    all {
      up' = true, phase' = "idle", mem' = m, saved' = m.length(), pendingCall' = -1,
      disk' = disk, torn' = if (FIXED) false else torn,
      persisted' = midsOf(disk), acked' = acked, failNext' = failNext, nextMid' = nextMid,
      bContextOk' = bContextOk, lastAction' = "resume",
    },
  }

  // A second process runs one `fen session send` turn against the same file.
  // It holds the backend lock, but A never takes it. load-strict refuses a
  // transcript with any malformed line.
  action otherSend = all {
    OTHER_WRITER, disk.length() > 0, not(torn),
    disk.select(l => l.kind == "garbage").length() == 0,
    nextMid + 1 <= MAX_MID,
    not(FIXED) or not(up),  // FIXED: interactive writers hold the lock too
    val u = { mid: nextMid, role: "user", call: -1 }
    val a = { mid: nextMid + 1, role: "asst", call: -1 }
    all {
      disk' = disk.append(msgLine(u)).append(msgLine(a)),
      bContextOk' = (bContextOk and contextValid(replay(disk).append(u))),
      acked' = acked.union(Set(u.mid, a.mid)),
      up' = up, phase' = phase, mem' = mem, saved' = saved, pendingCall' = pendingCall,
      torn' = torn, persisted' = persisted, failNext' = failNext, nextMid' = nextMid + 2,
      lastAction' = "otherSend",
    },
  }

  action failAppend = all {
    not(failNext),
    failNext' = true,
    up' = up, phase' = phase, mem' = mem, saved' = saved, pendingCall' = pendingCall,
    disk' = disk, torn' = torn, persisted' = persisted, acked' = acked,
    nextMid' = nextMid, bContextOk' = bContextOk, lastAction' = "failAppend",
  }

  action step = any {
    userPrompt,
    assistant(true),
    assistant(false),
    toolResult,
    cancel,
    crash(true),
    crash(false),
    resume,
    otherSend,
    failAppend,
    nondet cut = 1.to(8).oneOf()
    compact(cut),
  }

  // ---- properties ----

  // Every provider request (A's next call, or a `session send`) carries
  // Anthropic-valid tool pairing.
  val providerContextValid =
    bContextOk and ((up and phase == "llm") implies contextValid(mem))

  // After a flush the cursor considers complete, replaying the log rebuilds
  // exactly the context the live process holds.
  val replayMatchesMemory =
    (up and assistantPresent(mem) and saved == mem.length()) implies
      replay(disk) == (if (FIXED) repairDangling(mem) else mem)

  // A message a writer counted as saved is in the log.
  val ackedPersisted = acked.forall(x => midsOf(disk).contains(x))

  val noDuplicateEntries = msgsOf(disk).length() == midsOf(disk).size()

  // Every compaction entry's first-kept-entry-id names a readable message.
  val compactionResolves =
    disk.foldl(true, (ok, l) =>
      ok and (l.kind == "compaction" implies midsOf(disk).contains(l.keep)))

  // The replayed compaction keeps whole tool pairs and starts at a user turn.
  val compactionCutKeepsPairs =
    val ms = msgsOf(disk)
    val k = compactionIndex(disk)
    k >= 0 implies (
      ms[k].role == "user" and
      range(k, ms.length()).foldl(true, (ok, i) =>
        ok and (ms[i].role == "result" implies
          range(0, k).foldl(true, (ok2, j) =>
            ok2 and not(ms[j].role == "call" and ms[j].call == ms[i].call)))))

  // A doctor report with no issues means the transcript replays validly.
  val doctorCleanMeansReplayable =
    doctorIssues(disk) == 0 implies contextValid(replayRaw(disk))

  // `doctor --repair` output always replays validly.
  val doctorRepairReplayable = contextValid(replayRaw(doctorRepair(disk)))

  val allInvariants = and {
    providerContextValid, replayMatchesMemory, ackedPersisted, noDuplicateEntries,
    compactionResolves, compactionCutKeepsPairs, doctorCleanMeansReplayable,
    doctorRepairReplayable,
  }
}

// Stale-lock reclaim in the JSONL backend's acquire-lock: mkdir lock; on
// failure read owner, kill -0, re-read owner, os.remove owner, rmdir
// (result ignored), mkdir again; the winner writes its pid afterwards.
// Two `fen session send` processes start while a dead owner (pid 9) holds it.
module lock {
  const FIXED: bool

  pure val PROCS = Set(1, 2)
  pure val DEAD = 9

  var lockDir: bool
  var owner: int            // 0 = no owner file
  var pc: int -> str
  var seen: int -> int

  action init = all {
    lockDir' = true, owner' = DEAD,
    pc' = PROCS.mapBy(_ => "try"), seen' = PROCS.mapBy(_ => 0),
  }

  action tryMkdir(p: int): bool = all {
    pc.get(p) == "try",
    if (not(lockDir)) all { lockDir' = true, owner' = 0, pc' = pc.set(p, "own"), seen' = seen }
    else all { lockDir' = lockDir, owner' = owner, pc' = pc.set(p, "read"), seen' = seen },
  }

  action readOwner(p: int): bool = all {
    pc.get(p) == "read",
    // only a recorded owner whose process is gone is stale
    if (owner == DEAD)
      if (FIXED)
        // OS-level lock (e.g. lfs.lock / flock): released by the kernel on
        // death, so takeover is one atomic step.
        all { lockDir' = true, owner' = 0, pc' = pc.set(p, "own"), seen' = seen }
      else all { lockDir' = lockDir, owner' = owner, pc' = pc.set(p, "recheck"), seen' = seen.set(p, owner) }
    else all { lockDir' = lockDir, owner' = owner, pc' = pc.set(p, "fail"), seen' = seen },
  }

  action recheck(p: int): bool = all {
    pc.get(p) == "recheck",
    lockDir' = lockDir, owner' = owner, seen' = seen,
    pc' = pc.set(p, if (owner == seen.get(p)) "rmOwner" else "fail"),
  }

  action rmOwner(p: int): bool = all {
    pc.get(p) == "rmOwner",
    owner' = 0, lockDir' = lockDir, seen' = seen, pc' = pc.set(p, "rmdir"),
  }

  action rmdir(p: int): bool = all {
    pc.get(p) == "rmdir",
    lockDir' = if (owner == 0) false else lockDir,
    owner' = owner, seen' = seen, pc' = pc.set(p, "mk"),
  }

  action mk(p: int): bool = all {
    pc.get(p) == "mk",
    if (not(lockDir)) all { lockDir' = true, owner' = 0, pc' = pc.set(p, "own"), seen' = seen }
    else all { lockDir' = lockDir, owner' = owner, pc' = pc.set(p, "fail"), seen' = seen },
  }

  action writeOwner(p: int): bool = all {
    pc.get(p) == "own",
    owner' = p, lockDir' = lockDir, seen' = seen, pc' = pc.set(p, "hold"),
  }

  action release(p: int): bool = all {
    pc.get(p) == "hold",
    owner' = 0, lockDir' = false, seen' = seen, pc' = pc.set(p, "done"),
  }

  action step = {
    nondet p = PROCS.oneOf()
    any { tryMkdir(p), readOwner(p), recheck(p), rmOwner(p), rmdir(p), mk(p),
          writeOwner(p), release(p) }
  }

  // At most one process believes it holds the session lock.
  val lockMutex = PROCS.filter(p => pc.get(p) == "own" or pc.get(p) == "hold").size() <= 1
}

module current { import sessions(FIXED = false, OTHER_WRITER = true).* }
// Same code with one process per session: attributes violations to bugs.
module currentSolo { import sessions(FIXED = false, OTHER_WRITER = false).* }
module fixed { import sessions(FIXED = true, OTHER_WRITER = true).* }
module lockCurrent { import lock(FIXED = false).* }
module lockFixed { import lock(FIXED = true).* }
