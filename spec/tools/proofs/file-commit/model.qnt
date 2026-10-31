// Proof model: committing one file from write or edit (#654, #655, #656,
// #657).
//
// The `write` and `edit` machines of ../../model.qnt merged into one call:
// read a snapshot (edit; trivial for write), yield, write the new content in
// two chunks with a yield after each, close, commit, return.  Two kinds of
// concurrent writer touch the target while the call runs:
//
//   fen      another fen edit/write in a different process (a sibling
//            subagent).  Today's in-process file mutex does not order it.
//   outside  anything that takes no fen lock: the user's editor, `sed -i`
//            run by bash, a formatter.
//
// Not yielding keeps other coroutines and cancel (raised at a yield) out of a
// step, nothing more.  So every non-yielding stretch of the call that
// touches the disk more than once is split into steps here, and both writers
// may run between them.
//
// Code: extensions/behaviors/kernel/builtin-tools/write.fnl,
// extensions/behaviors/kernel/builtin-tools/edit.fnl (validate-edit-file,
// write-edit-file), packages/util/src/fen/util/file_mutex.fnl.
//
// The target design (all four fixes), against the five guarantees of
// FINDINGS.md:
//   #654  G1 atomic replacement: chunks go to a temp in the same directory;
//         one rename(2) replaces the target.  A failed temp is discarded.
//   #655  a failed write or close is reported as an error.
//   #656  G2 cancellation shielding: no yield from the commit to the return.
//   #657  G3 serialization: every fen edit/write holds a kernel lock on the
//         path from the read to the return.  G4 detection: just before the
//         rename, re-read (or compare size+mtime/hash) and fail with "file
//         changed since read".  Best effort: the check and the rename are two
//         steps, and an outside write between them is lost.  Modelled on top
//         of #654 (the check guards the rename).
module fileCommit {
  const FIXES: Set[str]

  pure val MAX_WRITES = 2
  pure val PHASES = Set("idle", "read", "c1", "c2", "flushed", "checked",
                        "closed", "done")

  // idle | read | c1 | c2 | flushed (closed, not committed) | checked |
  // closed (committed, before the trailing yield) | done
  var phase: str
  var disk: str           // orig | part | new: this call's effect on the target
  var ioErr: bool         // ENOSPC/EIO on a chunk or on close
  var writes: int         // concurrent writes so far (bounded)
  var pendFen: bool       // a fen-process write this call has not seen
  var pendOut: bool       // an outside write this call has not seen
  var windowWrite: bool   // an outside write landed between check and rename
  var lostFen: bool       // this call overwrote a fen-process write
  var lostOut: bool       // this call overwrote an outside write
  var result: str         // none | ok | error | cancelled

  pure def temp: bool = FIXES.contains("654")
  pure def checks: bool = FIXES.contains("654") and FIXES.contains("657")
  pure def locks: bool = FIXES.contains("657")

  action init = all {
    phase' = "idle", disk' = "orig", ioErr' = false, writes' = 0,
    pendFen' = false, pendOut' = false, windowWrite' = false,
    lostFen' = false, lostOut' = false, result' = "none",
  }

  // Assign every variable that a step of the call itself can change.
  action move(ph: str, d: str, pf: bool, po: bool, lf: bool, lo: bool,
              res: str): bool = all {
    phase' = ph, disk' = d, pendFen' = pf, pendOut' = po,
    lostFen' = lf, lostOut' = lo, result' = res,
    ioErr' = ioErr, writes' = writes, windowWrite' = windowWrite,
  }

  // Our bytes reach the target: whatever was written since and not seen is
  // overwritten.
  action overwrite(ph: str, d: str): bool =
    move(ph, d, false, false, lostFen or pendFen, lostOut or pendOut, result)

  action startWith(full: bool): bool = all {
    phase == "idle",
    phase' = "read", disk' = disk, ioErr' = full, writes' = writes,
    pendFen' = false, pendOut' = false, windowWrite' = windowWrite,
    lostFen' = lostFen, lostOut' = lostOut, result' = result,
  }

  action start = { nondet full = Set(true, false).oneOf() startWith(full) }

  // Today: open :w truncates the target in place.  #654: write the temp.
  action chunk1 = all {
    phase == "read",
    if (temp) move("c1", disk, pendFen, pendOut, lostFen, lostOut, result)
    else overwrite("c1", "part"),
  }

  action chunk2 = all {
    phase == "c1",
    if (temp) move("c2", disk, pendFen, pendOut, lostFen, lostOut, result)
    else overwrite("c2", if (ioErr) "part" else "new"),
  }

  // f:close.  #655: a failed write or close is an error (and, with #654, the
  // temp is discarded).
  action close = all {
    phase == "c2",
    if (FIXES.contains("655") and ioErr)
      move("done", disk, pendFen, pendOut, lostFen, lostOut, "error")
    else move("flushed", disk, pendFen, pendOut, lostFen, lostOut, result),
  }

  // The commit point.  #656: return without yielding.
  def committedPhase: str = if (FIXES.contains("656")) "done" else "closed"
  def committedResult: str = if (FIXES.contains("656")) "ok" else result

  // Today the bytes are already in place.  #654: rename the temp (unless its
  // write failed: it is discarded, and the target keeps the old content).
  // #657: the check comes first (see check / rename).
  action commit = all {
    phase == "flushed", not(checks),
    if (temp) {
      if (ioErr) move(committedPhase, disk, pendFen, pendOut, lostFen, lostOut, committedResult)
      else move(committedPhase, "new", false, false, lostFen or pendFen,
                lostOut or pendOut, committedResult)
    }
    else move(committedPhase, disk, pendFen, pendOut, lostFen, lostOut, committedResult),
  }

  // #657 detection: compare with the snapshot; fail if anyone wrote since.
  action check = all {
    phase == "flushed", checks,
    if (pendFen or pendOut)
      move("done", disk, pendFen, pendOut, lostFen, lostOut, "error")
    else move("checked", disk, pendFen, pendOut, lostFen, lostOut, result),
  }

  action rename = all {
    phase == "checked",
    if (ioErr) move(committedPhase, disk, pendFen, pendOut, lostFen, lostOut, committedResult)
    else move(committedPhase, "new", false, false, lostFen or pendFen,
              lostOut or pendOut, committedResult),
  }

  // The trailing maybe-yield, then ok.
  action ret = all {
    phase == "closed",
    move("done", disk, pendFen, pendOut, lostFen, lostOut, "ok"),
  }

  // Cancel is raised at a yield: after the read, after each chunk, and (today)
  // after the commit.
  action cancel = all {
    Set("read", "c1", "c2", "closed").contains(phase),
    move("done", disk, pendFen, pendOut, lostFen, lostOut, "cancelled"),
  }

  // Concurrent writers act while the call is between its read and its
  // return.  A fen writer waits on the #657 lock instead.
  def active: bool = not(Set("idle", "done").contains(phase))

  action fenWrite = all {
    active, writes < MAX_WRITES, not(locks),
    phase' = phase, disk' = disk, ioErr' = ioErr, writes' = writes + 1,
    pendFen' = true, pendOut' = pendOut, windowWrite' = windowWrite,
    lostFen' = lostFen, lostOut' = lostOut, result' = result,
  }

  action outsideWrite = all {
    active, writes < MAX_WRITES,
    phase' = phase, disk' = disk, ioErr' = ioErr, writes' = writes + 1,
    pendFen' = pendFen, pendOut' = true,
    windowWrite' = (windowWrite or phase == "checked"),
    lostFen' = lostFen, lostOut' = lostOut, result' = result,
  }

  action stutter = all {
    phase == "done",
    move(phase, disk, pendFen, pendOut, lostFen, lostOut, result),
  }

  action step = any {
    start, chunk1, chunk2, close, commit, check, rename, ret, cancel,
    fenWrite, outsideWrite, stutter,
  }

  // ---------------------------------------------------------------- properties
  // G1: a reader of the target, or the disk after the process dies at this
  // point, sees the old or the new content, never a prefix.
  val noTornTarget = disk != "part"

  // An ok result means the new bytes are on disk.
  val okMeansWritten = result == "ok" implies disk == "new"

  // An error result means nothing was changed.
  val errorMeansUnchanged = result == "error" implies disk == "orig"

  // G2: a cancelled result means nothing was changed (the model will retry).
  val cancelledMeansUnchanged = result == "cancelled" implies disk == "orig"

  // G3: the call never overwrites another fen writer's commit.
  val noLostFenUpdate = not(lostFen)

  // G4 (best effort): an outside write is lost only if it landed in the
  // check/rename window.
  val outsideLossOnlyInWindow = lostOut implies windowWrite

  // Not provided by any design here (needs a filesystem compare-and-swap).
  val noLostUpdate = not(lostFen or lostOut)

  val guarantees = and {
    noTornTarget, okMeansWritten, errorMeansUnchanged, cancelledMeansUnchanged,
    noLostFenUpdate, outsideLossOnlyInWindow,
  }

  // Inductive strengthening for the target design.
  val inductiveInv = and {
    phase.in(PHASES), disk.in(Set("orig", "part", "new")),
    ioErr.in(Set(true, false)), writes.in(0.to(MAX_WRITES)),
    pendFen.in(Set(true, false)), pendOut.in(Set(true, false)),
    windowWrite.in(Set(true, false)), lostFen.in(Set(true, false)),
    lostOut.in(Set(true, false)),
    result.in(Set("none", "ok", "error", "cancelled")),
    guarantees,
    (phase != "done") iff (result == "none"),
    disk == "new" implies (phase == "done" and result == "ok"),
    phase != "closed",
    not(pendFen),
    phase == "checked" implies (pendOut iff windowWrite),
    Set("idle", "read", "c1", "c2", "flushed").contains(phase) implies
      not(windowWrite or lostOut),
    Set("flushed", "checked").contains(phase) implies not(ioErr),
  }
}

module current { import fileCommit(FIXES = Set()).* }
module fixed { import fileCommit(FIXES = Set("654", "655", "656", "657")).* }
