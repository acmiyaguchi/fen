// Model of fen's tool execution below the agent loop, as it works today.
//
// Eight small machines run side by side; each step advances one of them.
//
//   bash    fen.util.process start-captured/run-captured: child leader in its
//           own session (setsid), one more group member that shares the pipe
//           (a backgrounded or nested command), SIGTERM at the deadline,
//           SIGKILL after the grace window, abort (cancel) = SIGKILL, finish
//           once the leader is reaped and the pipe hit EOF or the 150 ms
//           post-exit window elapsed.
//   popen   grep/find/ls: io.popen + read-pipe-close; a cancel raised at a
//           yield closes the FILE*, and pclose waits for the shell.
//   write   write.fnl: mkdir -p, io.open :w (truncates), 16 KiB chunks with a
//           yield after each, close, yield, ok.  f:write/f:close results are
//           not checked.
//   edit    edit.fnl single file: under the file mutex, read snapshot, yield,
//           validate, yield, write snapshot-derived result, yield, ok.  Other
//           writers that do not take the mutex (bash in a sibling subagent of
//           the same parallel batch, a user's editor) can write at any yield.
//   batch   edit.fnl `files` shape: preflight, then per file lock, re-read,
//           write, yield.
//   out     bash result text: process tail cap (bytes), exit tag appended,
//           then tools.scrub-result (escape invalid/control bytes as \xNN,
//           head-keep to FEN_TOOL_RESULT_MAX_BYTES).
//   ov      edit find-all uniqueness count (overlapping occurrences).
//   disp    tools.execute dispatch: --tools/--denied-tools/--no-tools filter
//           (agent.tools), before-tool hooks (fail closed), schema validation,
//           then execute; side chat narrows to read-only; subagent child
//           policy never widens.
//
// FIXED selects the candidate fixes listed in FINDINGS.md.
module tools {
  const FIXED: bool

  // ---------------------------------------------------------------- bash
  type Bash = {
    started: bool, leaderAlive: bool, memberAlive: bool,
    leaderIgnoresTerm: bool, memberIgnoresTerm: bool,
    termSent: bool, killSent: bool, timedOut: bool, cancelled: bool,
    done: bool,
  }

  // ---------------------------------------------------------------- popen
  // phase: idle | reading | closing | done
  type Popen = { phase: str, childAlive: bool, killed: bool, result: str }

  // ---------------------------------------------------------------- write
  // phase: idle | pre | c1 | c2 | closed | done
  // disk:  orig | part | new
  type Write = { phase: str, disk: str, ioErr: bool, result: str }

  // ---------------------------------------------------------------- edit
  // phase: idle | read | written | done
  type Edit = {
    phase: str, snapVer: int, diskVer: int, committed: bool, lost: bool,
    result: str,
  }

  // ---------------------------------------------------------------- batch
  // phase: idle | pre | aDone | bDone | done
  type Batch = { phase: str, a: bool, b: bool, result: str }

  // ---------------------------------------------------------------- out
  // Units are bytes: "a" ascii, "L"/"C" lead/continuation of a 2-byte char,
  // "x" a control or invalid byte, "T" the exit tag.
  type Out = { ran: bool, raw: List[str], trimmed: List[str], kept: List[str] }

  // ---------------------------------------------------------------- disp
  type Disp = {
    ran: bool, path: str, name: str, parentAllowed: Set[str],
    hook: str, argsValid: bool, executed: bool,
  }

  // ---------------------------------------------------------------- ov
  // edit's uniqueness check on a 4-byte file over {a,b} with old_string "aa".
  type Ov = { ran: bool, content: List[str], found: int, actual: int }

  pure val TAIL_BYTES = 3     // process DEFAULT-MAX-BYTES, scaled
  pure val RESULT_LIMIT = 8   // FEN_TOOL_RESULT_MAX_BYTES, scaled
  pure val MAX_EXTERNAL = 2

  pure val TOOLS = Set("read", "grep", "bash", "edit", "subagent")
  pure val READ_ONLY = Set("read", "grep")

  var bash: Bash
  var popen: Popen
  var wr: Write
  var ed: Edit
  var batch: Batch
  var out: Out
  var disp: Disp
  var ov: Ov
  var lastAction: str

  action init = all {
    bash' = { started: false, leaderAlive: false, memberAlive: false,
              leaderIgnoresTerm: false, memberIgnoresTerm: false,
              termSent: false, killSent: false, timedOut: false,
              cancelled: false, done: false },
    popen' = { phase: "idle", childAlive: false, killed: false, result: "none" },
    wr' = { phase: "idle", disk: "orig", ioErr: false, result: "none" },
    ed' = { phase: "idle", snapVer: 0, diskVer: 0, committed: false,
            lost: false, result: "none" },
    batch' = { phase: "idle", a: false, b: false, result: "none" },
    out' = { ran: false, raw: [], trimmed: [], kept: [] },
    disp' = { ran: false, path: "", name: "", parentAllowed: Set(),
              hook: "allow", argsValid: true, executed: false },
    ov' = { ran: false, content: [], found: 0, actual: 0 },
    lastAction' = "init",
  }

  action keep_bash = all {
    ov' = ov,
    popen' = popen,
    wr' = wr,
    ed' = ed,
    batch' = batch,
    out' = out,
    disp' = disp,
  }
  action keep_popen = all {
    ov' = ov,
    bash' = bash,
    wr' = wr,
    ed' = ed,
    batch' = batch,
    out' = out,
    disp' = disp,
  }
  action keep_wr = all {
    ov' = ov,
    bash' = bash,
    popen' = popen,
    ed' = ed,
    batch' = batch,
    out' = out,
    disp' = disp,
  }
  action keep_ed = all {
    ov' = ov,
    bash' = bash,
    popen' = popen,
    wr' = wr,
    batch' = batch,
    out' = out,
    disp' = disp,
  }
  action keep_batch = all {
    ov' = ov,
    bash' = bash,
    popen' = popen,
    wr' = wr,
    ed' = ed,
    out' = out,
    disp' = disp,
  }
  action keep_out = all {
    ov' = ov,
    bash' = bash,
    popen' = popen,
    wr' = wr,
    ed' = ed,
    batch' = batch,
    disp' = disp,
  }
  action keep_disp = all {
    ov' = ov,
    bash' = bash,
    popen' = popen,
    wr' = wr,
    ed' = ed,
    batch' = batch,
    out' = out,
  }

  // ================================================================ bash
  pure def groupAlive(b: Bash): bool = b.leaderAlive or b.memberAlive

  action bStart = all {
    not(bash.started),
    nondet li = Set(true, false).oneOf()
    nondet mi = Set(true, false).oneOf()
    bash' = { ...bash, started: true, leaderAlive: true, memberAlive: true,
              leaderIgnoresTerm: li, memberIgnoresTerm: mi },
    keep_bash, lastAction' = "bStart",
  }

  // The command (leader) or the extra member exits on its own.
  action bLeaderExit = all {
    bash.started, not(bash.done), bash.leaderAlive,
    bash' = { ...bash, leaderAlive: false },
    keep_bash, lastAction' = "bLeaderExit",
  }

  action bMemberExit = all {
    bash.started, not(bash.done), bash.memberAlive,
    bash' = { ...bash, memberAlive: false },
    keep_bash, lastAction' = "bMemberExit",
  }

  // tick!: deadline passed while the leader is not reaped -> SIGTERM group.
  action bDeadline = all {
    bash.started, not(bash.done), bash.leaderAlive, not(bash.termSent),
    bash' = { ...bash, termSent: true, timedOut: true,
              leaderAlive: bash.leaderIgnoresTerm,
              memberAlive: bash.memberAlive and bash.memberIgnoresTerm },
    keep_bash, lastAction' = "bDeadline",
  }

  // tick!: grace elapsed -> SIGKILL group, but only while the leader is
  // unreaped (`(and term-sent? (not reaped?) (not kill-sent?) ...)`).
  action bGrace = all {
    bash.started, not(bash.done), bash.termSent, not(bash.killSent),
    if (FIXED) groupAlive(bash) else bash.leaderAlive,
    bash' = { ...bash, killSent: true, leaderAlive: false, memberAlive: false },
    keep_bash, lastAction' = "bGrace",
  }

  // abort!: cancelled raised by yield-fn; send-kill! is gated on not reaped.
  action bCancel = all {
    bash.started, not(bash.done), not(bash.cancelled),
    val kill = if (FIXED) groupAlive(bash) else bash.leaderAlive
    bash' = { ...bash, cancelled: true,
              killSent: bash.killSent or kill,
              leaderAlive: bash.leaderAlive and not(kill),
              memberAlive: bash.memberAlive and not(kill) },
    keep_bash, lastAction' = "bCancel",
  }

  // Leader reaped; EOF (no holder) or the post-exit window (150 ms, shorter
  // than the 200 ms kill grace) elapsed -> close fd, return a result.
  // FIXED: an abnormal end SIGKILLs the group before closing (the pgid cannot
  // be reused while any member is alive).
  action bFinish = all {
    bash.started, not(bash.done), not(bash.leaderAlive),
    val abnormal = bash.timedOut or bash.cancelled
    bash' = { ...bash, done: true,
              memberAlive: bash.memberAlive and not(FIXED and abnormal),
              killSent: bash.killSent or (FIXED and abnormal and bash.memberAlive) },
    keep_bash, lastAction' = "bFinish",
  }

  // ================================================================ popen
  action pStart = all {
    popen.phase == "idle",
    popen' = { ...popen, phase: "reading", childAlive: true },
    keep_popen, lastAction' = "pStart",
  }

  action pChildExit = all {
    popen.childAlive,
    popen' = { ...popen, childAlive: false },
    keep_popen, lastAction' = "pChildExit",
  }

  action pEof = all {
    popen.phase == "reading", not(popen.childAlive),
    popen' = { ...popen, phase: "done", result: "ok" },
    keep_popen, lastAction' = "pEof",
  }

  // Cancel at the EAGAIN yield in read-pipe-coop: pipe:close() -> pclose
  // blocks the whole Lua state until the shell exits. FIXED: run through
  // start-captured, whose abort SIGKILLs the group.
  action pCancel = all {
    popen.phase == "reading",
    popen' = { ...popen, phase: "closing", killed: FIXED,
               childAlive: popen.childAlive and not(FIXED) },
    keep_popen, lastAction' = "pCancel",
  }

  action pCloseReturns = all {
    popen.phase == "closing", not(popen.childAlive),
    popen' = { ...popen, phase: "done", result: "cancelled" },
    keep_popen, lastAction' = "pCloseReturns",
  }

  // ================================================================ write
  action wStart = all {
    wr.phase == "idle",
    nondet full = Set(true, false).oneOf()   // ENOSPC / EIO on write or close
    wr' = { ...wr, phase: "pre", ioErr: full },
    keep_wr, lastAction' = "wStart",
  }

  // open :w truncates, chunk 1 written, yield.  FIXED: temp file.
  action wChunk1 = all {
    wr.phase == "pre",
    wr' = { ...wr, phase: "c1", disk: if (FIXED) wr.disk else "part" },
    keep_wr, lastAction' = "wChunk1",
  }

  action wChunk2 = all {
    wr.phase == "c1",
    wr' = { ...wr, phase: "c2",
            disk: if (FIXED) wr.disk else if (wr.ioErr) "part" else "new" },
    keep_wr, lastAction' = "wChunk2",
  }

  // f:close (result ignored), then the trailing maybe-yield.
  // FIXED: check write/close, rename temp over target, return without yield.
  action wClose = all {
    wr.phase == "c2",
    if (FIXED)
      wr' = { ...wr, phase: "done",
              disk: if (wr.ioErr) wr.disk else "new",
              result: if (wr.ioErr) "error" else "ok" }
    else
      wr' = { ...wr, phase: "closed" },
    keep_wr, lastAction' = "wClose",
  }

  action wReturn = all {
    wr.phase == "closed",
    wr' = { ...wr, phase: "done", result: "ok" },
    keep_wr, lastAction' = "wReturn",
  }

  action wCancel = all {
    Set("pre", "c1", "c2", "closed").contains(wr.phase),
    wr' = { ...wr, phase: "done", result: "cancelled" },
    keep_wr, lastAction' = "wCancel",
  }

  // ================================================================ edit
  action eStart = all {
    ed.phase == "idle",
    ed' = { ...ed, phase: "read", snapVer: ed.diskVer },
    keep_ed, lastAction' = "eStart",
  }

  // A writer that does not take fen's file mutex (bash `sed -i` in a sibling
  // subagent of the same parallel batch, or the user's editor).
  action eExternalWrite = all {
    ed.phase == "read", ed.diskVer < MAX_EXTERNAL,
    ed' = { ...ed, diskVer: ed.diskVer + 1 },
    keep_ed, lastAction' = "eExternalWrite",
  }

  // write-edit-file: apply edits to the snapshot and write it.
  // FIXED: re-read and compare in the same non-yielding step, then rename.
  action eWrite = all {
    ed.phase == "read",
    if (FIXED and ed.diskVer != ed.snapVer)
      ed' = { ...ed, phase: "done", result: "error" }
    else
      ed' = { ...ed, phase: if (FIXED) "done" else "written",
              lost: ed.lost or ed.diskVer != ed.snapVer,
              diskVer: ed.diskVer + 1, committed: true,
              result: if (FIXED) "ok" else ed.result },
    keep_ed, lastAction' = "eWrite",
  }

  action eReturn = all {
    ed.phase == "written",
    ed' = { ...ed, phase: "done", result: "ok" },
    keep_ed, lastAction' = "eReturn",
  }

  action eCancel = all {
    ed.phase == "read" or ed.phase == "written",
    ed' = { ...ed, phase: "done", result: "cancelled" },
    keep_ed, lastAction' = "eCancel",
  }

  // ================================================================ batch
  action bfStart = all {
    batch.phase == "idle",
    batch' = { ...batch, phase: "pre" },
    keep_batch, lastAction' = "bfStart",
  }

  // Current: lock a, re-read, write, yield.  FIXED: stage every file, then
  // commit all of them in one non-yielding step.
  action bfWriteA = all {
    batch.phase == "pre",
    if (FIXED)
      batch' = { ...batch, phase: "done", a: true, b: true, result: "ok" }
    else
      batch' = { ...batch, phase: "aDone", a: true },
    keep_batch, lastAction' = "bfWriteA",
  }

  action bfWriteB = all {
    batch.phase == "aDone",
    batch' = { ...batch, phase: "bDone", b: true },
    keep_batch, lastAction' = "bfWriteB",
  }

  action bfReturn = all {
    batch.phase == "bDone",
    batch' = { ...batch, phase: "done", result: "ok" },
    keep_batch, lastAction' = "bfReturn",
  }

  action bfCancel = all {
    Set("pre", "aDone", "bDone").contains(batch.phase),
    batch' = { ...batch, phase: "done", result: "cancelled" },
    keep_batch, lastAction' = "bfCancel",
  }

  // ================================================================ out
  pure def expand(t: str): List[str] =
    if (t == "e") ["L", "C"] else if (t == "none") [] else [t]

  // process trim-tail: (string.sub out (- max-bytes)).
  // FIXED: skip leading continuation bytes.
  pure def tailTrim(bs: List[str]): List[str] =
    val n = bs.length()
    val t = if (n > TAIL_BYTES) bs.slice(n - TAIL_BYTES, n) else bs
    if (FIXED and t.length() > 0 and t[0] == "C") t.slice(1, t.length()) else t

  // Bytes after sanitize: control/invalid bytes become 4-byte \xNN escapes.
  pure def unitSize(bs: List[str], i: int): int =
    val u = bs[i]
    if (u == "x") 4
    else if (u == "C") (if (i > 0 and bs[i - 1] == "L") 1 else 4)
    else if (u == "L") (if (i + 1 < bs.length() and bs[i + 1] == "C") 1 else 4)
    else 1

  // utf8-prefix head-keep up to `limit` sanitized bytes.
  pure def headKeepList(bs: List[str], limit: int): List[str] =
    range(0, bs.length()).foldl({ kept: List(), used: 0, stop: false }, (acc, i) =>
      if (acc.stop) acc
      else
        val s = unitSize(bs, i)
        if (acc.used + s > limit) { ...acc, stop: true }
        else { kept: acc.kept.append(bs[i]), used: acc.used + s, stop: false }
    ).kept

  // tools.scrub-result over bash result-text.
  // FIXED: the cap reserves the trailer line (exit/timeout tag).
  pure def scrub(bs: List[str]): List[str] =
    if (FIXED)
      headKeepList(bs.slice(0, bs.length() - 1), RESULT_LIMIT - 1).append("T")
    else headKeepList(bs, RESULT_LIMIT)

  action oRun = all {
    not(out.ran),
    nondet t1 = Set("a", "e", "x", "none").oneOf()
    nondet t2 = Set("a", "e", "x", "none").oneOf()
    nondet t3 = Set("a", "e", "x", "none").oneOf()
    val raw = expand(t1).concat(expand(t2)).concat(expand(t3))
    val trimmed = tailTrim(raw)
    out' = { ran: true, raw: raw, trimmed: trimmed,
             kept: scrub(trimmed.append("T")) },
    keep_out, lastAction' = "oRun",
  }

  // ================================================================ disp
  // fen.tool_policy.policy -> agent.tools (the executable registry).
  pure def registry(kind: str, names: Set[str]): Set[str] =
    if (kind == "none") TOOLS
    else if (kind == "notools") Set()
    else if (kind == "allow") TOOLS.intersect(names)
    else TOOLS.exclude(names)

  // fen.tool_policy.narrow (side chat's read-only set).
  pure def narrow(cands: Set[str], kind: str, names: Set[str]): Set[str] =
    if (kind == "notools") Set()
    else if (kind == "allow") cands.intersect(names)
    else if (kind == "deny") cands.exclude(names)
    else cands

  // subagent child-tool-policy -> the child's registry ({} = refused/none).
  pure def childRegistry(kind: str, names: Set[str], cfgSet: bool,
                         cfg: Set[str]): Set[str] =
    if (kind == "none") (if (cfgSet) cfg else TOOLS)
    else if (kind == "notools") Set()
    else if (kind == "allow") (if (cfgSet) cfg.intersect(names) else names.intersect(TOOLS))
    else (if (cfgSet) cfg.exclude(names) else TOOLS.exclude(names))

  action dRun = all {
    not(disp.ran),
    nondet kind = Set("none", "allow", "deny", "notools").oneOf()
    nondet names = TOOLS.powerset().oneOf()
    nondet path = Set("direct", "sidechat", "subagent").oneOf()
    nondet name = TOOLS.union(Set("unknown")).oneOf()
    nondet hook = Set("allow", "block", "throw").oneOf()
    nondet valid = Set(true, false).oneOf()
    nondet cfgSet = Set(true, false).oneOf()
    nondet cfg = TOOLS.powerset().oneOf()
    // CLI rejects --tools/--denied-tools naming nothing or an unknown tool.
    all {
      (kind == "allow" or kind == "deny") implies names != Set(),
      val parent = registry(kind, names)
      val reach =
        if (path == "direct") parent
        else if (path == "sidechat") narrow(READ_ONLY, kind, names)
        else childRegistry(kind, names, cfgSet, cfg)
      // tools.execute: find-tool -> restriction -> before-tool hooks
      // (a throwing hook blocks) -> schema validation -> execute.
      val executed = reach.contains(name) and hook == "allow" and valid
      disp' = { ran: true, path: path, name: name, parentAllowed: parent,
                hook: hook, argsValid: valid, executed: executed },
    },
    keep_disp, lastAction' = "dRun",
  }

  // ================================================================ ov
  pure def isAA(c: List[str], i: int): bool =
    i + 1 < c.length() and c[i] == "a" and c[i + 1] == "a"

  // edit find-all: after a hit at pos, resume at pos + #old (non-overlapping).
  // FIXED: resume at pos + 1, so overlapping occurrences count.
  pure def countHits(c: List[str]): int =
    range(0, c.length()).foldl({ n: 0, next: 0 }, (acc, i) =>
      if (i >= acc.next and isAA(c, i))
        { n: acc.n + 1, next: if (FIXED) i + 1 else i + 2 }
      else acc
    ).n

  pure def actualCount(c: List[str]): int =
    range(0, c.length()).foldl(0, (n, i) => if (isAA(c, i)) n + 1 else n)

  action vRun = all {
    not(ov.ran),
    nondet c0 = Set("a", "b").oneOf()
    nondet c1 = Set("a", "b").oneOf()
    nondet c2 = Set("a", "b").oneOf()
    nondet c3 = Set("a", "b").oneOf()
    val c = [c0, c1, c2, c3]
    ov' = { ran: true, content: c, found: countHits(c), actual: actualCount(c) },
    bash' = bash, popen' = popen, wr' = wr, ed' = ed, batch' = batch,
    out' = out, disp' = disp, lastAction' = "vRun",
  }

  // ================================================================ step
  action step = any {
    bStart, bLeaderExit, bMemberExit, bDeadline, bGrace, bCancel, bFinish,
    pStart, pChildExit, pEof, pCancel, pCloseReturns,
    wStart, wChunk1, wChunk2, wClose, wReturn, wCancel,
    eStart, eExternalWrite, eWrite, eReturn, eCancel,
    bfStart, bfWriteA, bfWriteB, bfReturn, bfCancel,
    oRun,
    dRun,
    vRun,
  }

  // ================================================================ properties
  // A timed-out or cancelled bash call leaves no live process in its group.
  val noLiveProcessAfterAbnormalEnd =
    (bash.done and (bash.timedOut or bash.cancelled)) implies not(bash.memberAlive)

  // SIGKILL is only ever sent for a timeout or cancel.
  val killOnlyOnAbnormalEnd = bash.killSent implies (bash.timedOut or bash.cancelled)

  // The tool thread never sits in a non-yielding wait on a child that has
  // not been told to die (the presenter loop would freeze unboundedly).
  val noUnboundedBlockingWait =
    (popen.phase == "closing" and popen.childAlive) implies popen.killed

  // A finished write/edit/batch never leaves a torn file behind.
  val noTornFile = wr.result != "none" implies wr.disk != "part"

  // An ok result means the bytes are on disk.
  val okMeansWritten = wr.result == "ok" implies wr.disk == "new"

  // A cancelled result means nothing was changed (the model will retry).
  val cancelledMeansUnchanged = and {
    wr.result == "cancelled" implies wr.disk == "orig",
    ed.result == "cancelled" implies not(ed.committed),
    batch.result == "cancelled" implies not(batch.a or batch.b),
  }

  // Edit's result is computed from what is on disk at write time.
  val noLostUpdate = not(ed.lost)

  // A multi-file edit applies all files or none.
  val batchAllOrNothing = batch.result != "none" implies batch.a == batch.b

  // Truncation never loses the exit/timeout tag the model reads.
  val exitStatusVisible =
    out.ran implies out.kept.foldl(false, (f, u) => f or u == "T")

  // The tail cap never starts the output inside a UTF-8 character.
  val noSplitChar =
    (out.ran and out.trimmed.length() > 0) implies out.trimmed[0] != "C"

  // Tools outside the parent's policy are unreachable on every path.
  val deniedUnreachable =
    disp.executed implies disp.parentAllowed.contains(disp.name)

  // A blocking or failing before-tool hook always prevents execution.
  val hookVetoFinal = (disp.ran and disp.hook != "allow") implies not(disp.executed)

  // Nothing runs on arguments that failed schema validation.
  val validatedBeforeEffect = disp.executed implies disp.argsValid

  // edit accepts an old_string only when it occurs exactly once.
  val uniqueMatchIsUnique = (ov.ran and ov.found == 1) implies ov.actual == 1

  val allInvariants = and {
    uniqueMatchIsUnique,
    noLiveProcessAfterAbnormalEnd, killOnlyOnAbnormalEnd,
    noUnboundedBlockingWait, noTornFile, okMeansWritten,
    cancelledMeansUnchanged, noLostUpdate, batchAllOrNothing,
    exitStatusVisible, noSplitChar, deniedUnreachable, hookVetoFinal,
    validatedBeforeEffect,
  }
}

module current { import tools(FIXED = false).* }
module fixed { import tools(FIXED = true).* }
