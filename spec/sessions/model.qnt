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
// FIXES names the candidate fixes (by issue) so the same invariants can be
// checked against today's code, each fix alone, and all of them together.
module sessions {
  // Replay repair, the provider rule, and the doctor's pairing check come from
  // the close-turn core (#668): one rule for memory and disk.
  import turn.* from "../core/turn/turn"

  const FIXES: Set[str]
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

  // The core's view of a message. An :aborted marker is a turn boundary for
  // replay, but build-context drops it before any provider sees it.
  pure def planEntry(m: Msg): Entry =
    if (m.role == "call") eAsst([m.call])
    else if (m.role == "result") eResult(m.call)
    else if (m.role == "asst") eAsst(NOCALLS)
    else eUser                                    // user, summary, aborted

  pure def planEntries(ms: List[Msg]): List[Entry] =
    ms.foldl(NOENTRIES, (acc, m) => acc.append(planEntry(m)))

  // Candidate fix: replay closes every interrupted call with a synthetic
  // result (core `replayPlan`, the same rule as close-turn in memory), for
  // every provider, instead of the OpenAI converters' private repair.
  pure def closeReplay(ms: List[Msg]): List[Msg] =
    replayPlan(planEntries(ms)).foldl(NOMSGS, (acc, st) =>
      acc.append(if (st.src >= 0) ms[st.src] else synth(st.call)))

  pure def replay(disk: List[Line]): List[Msg] =
    if (FIXES.contains("639")) closeReplay(replayRaw(disk)) else replayRaw(disk)

  // Anthropic-shaped validity (no converter-side repair): every tool call is
  // immediately followed by its result and every result immediately follows
  // its call (core rule). :aborted markers are dropped by build-context.
  pure def contextValid(ms: List[Msg]): bool =
    turnValid(planEntries(ms.select(m => m.role != "aborted")))

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

  // Candidate fix: the doctor reports and repairs exactly what replay would
  // change (core `replayRepairs` / `replayPlan` over the message entries);
  // compaction entries are kept in order, malformed lines dropped.
  pure def msgLineIdx(disk: List[Line]): List[int] =
    range(0, disk.length()).select(i => disk[i].kind == "msg")

  pure def lineEntries(disk: List[Line], mi: List[int]): List[Entry] =
    mi.foldl(NOENTRIES, (acc, i) => acc.append(planEntry(disk[i].msg)))

  pure def doctorIssuesCore(disk: List[Line]): int =
    disk.select(l => l.kind == "garbage").length()
      + replayRepairs(lineEntries(disk, msgLineIdx(disk)))

  pure def keepCompactions(out: List[Line], disk: List[Line], lo: int, hi: int): List[Line] =
    range(lo, hi).foldl(out, (o, j) => if (disk[j].kind == "compaction") o.append(disk[j]) else o)

  pure def doctorRepairCore(disk: List[Line]): List[Line] =
    val mi = msgLineIdx(disk)
    val r = replayPlan(lineEntries(disk, mi)).foldl({ out: NOLINES, ptr: 0 }, (st, p) =>
      if (p.src < 0) { out: st.out.append(msgLine(synth(p.call))), ptr: st.ptr }
      else { out: keepCompactions(st.out, disk, st.ptr, mi[p.src]).append(disk[mi[p.src]]),
             ptr: mi[p.src] + 1 })
    keepCompactions(r.out, disk, r.ptr, disk.length())

  pure def doctorIssues(disk: List[Line]): int =
    if (FIXES.contains("643")) doctorIssuesCore(disk) else doctorIssuesById(disk)
  pure def doctorRepair(disk: List[Line]): List[Line] =
    if (FIXES.contains("643")) doctorRepairCore(disk) else doctorRepairById(disk)

  // ---- writer: append-entry + flush closure ----
  type FS = { disk: List[Line], torn: bool, saved: int, persisted: Set[int],
              acked: Set[int], fail: bool, stopped: bool }

  // Today a torn tail swallows the next line. Fix #640 terminates it on open
  // (see `resume`), so a writer never appends onto a partial line.
  pure def appendLine(disk: List[Line], torn: bool, l: Line): { disk: List[Line], torn: bool } =
    if (torn) { disk: disk.replaceAt(disk.length() - 1, GARBAGE), torn: false }
    else { disk: disk.append(l), torn: false }

  pure def flushStep(s: FS, m: Msg): FS =
    if (s.stopped) s
    else if (s.fail)
      // write error (ENOSPC, EIO, unopenable dir): append returns nil
      if (FIXES.contains("641")) { ...s, fail: false, stopped: true }
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
    // Fix #641: every kept message must be persisted, not only the first.
    val idsOk = fs.persisted.contains(firstKept) and (not(FIXES.contains("641")) or fs.saved == mem.length())
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
      disk' = disk, torn' = if (FIXES.contains("640")) false else torn,
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
    not(FIXES.contains("642")) or not(up),  // fix #642: interactive writers hold the lock too
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
      replay(disk) == (if (FIXES.contains("639")) closeReplay(mem) else mem)

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

// Stale-lock reclaim (#644) is its own proof model: proofs/lock/model.qnt.
// The lockCurrent and lockFixed rows name that model's instances (loaded by
// `lockInstances` below), so these rows and the proof check one module.

module current { import sessions(FIXES = Set(), OTHER_WRITER = true).* }
// Same code with one process per session: attributes violations to bugs.
module currentSolo { import sessions(FIXES = Set(), OTHER_WRITER = false).* }
module fixed {
  import sessions(FIXES = Set("639", "640", "641", "642", "643"), OTHER_WRITER = true).*
}
// One fix at a time, with one process per session (#642 needs the second
// process, so its instance keeps it).
module fix639 { import sessions(FIXES = Set("639"), OTHER_WRITER = false).* }
module fix640 { import sessions(FIXES = Set("640"), OTHER_WRITER = false).* }
module fix641 { import sessions(FIXES = Set("641"), OTHER_WRITER = false).* }
module fix640641 { import sessions(FIXES = Set("640", "641"), OTHER_WRITER = false).* }
module fix642 { import sessions(FIXES = Set("642"), OTHER_WRITER = true).* }
module fix643 { import sessions(FIXES = Set("643"), OTHER_WRITER = true).* }
// Loads proofs/lock/model.qnt, whose lockCurrent and lockFixed instances
// the lock rows name.
module lockInstances { import lockCurrent.* from "./proofs/lock/model" }
