// Proof model: a multi-file edit (`files` shape) over two files (#656).
//
// The `batch` machine of ../../model.qnt on its own.  Today: preflight every
// file, then for each file take its lock, re-read, validate, write, and yield.
// A cancel lands at any of those yields; the process can also die (crash,
// SIGKILL) at any point.
//
// Code: extensions/behaviors/kernel/builtin-tools/edit.fnl (run-edit-batch).
//
// The #656 fix: write every file to a temp first (yields allowed, targets
// untouched), then rename them all with no yield in between.  That makes the
// batch atomic with respect to cancel (G2), not to a crash (G5): the renames
// are separate system calls, one file each, and the process can die between
// them.  Crash atomicity would need a commit record (an intent log replayed
// at startup); no design here provides it.
module multiFileCommit {
  const FIXES: Set[str]

  // idle | pre | staged | aDone | bDone | done
  var phase: str
  var a: bool             // file a has the new content
  var b: bool
  var result: str         // none | ok | cancelled | crashed

  pure def fix656: bool = FIXES.contains("656")

  action init = all { phase' = "idle", a' = false, b' = false, result' = "none" }

  action start = all {
    phase == "idle",
    phase' = "pre", a' = a, b' = b, result' = result,
  }

  // Today: lock a, re-read, write, yield.
  action writeA = all {
    phase == "pre", not(fix656),
    phase' = "aDone", a' = true, b' = b, result' = result,
  }

  // #656: stage both files as temps.
  action stage = all {
    phase == "pre", fix656,
    phase' = "staged", a' = a, b' = b, result' = result,
  }

  action renameA = all {
    phase == "staged",
    phase' = "aDone", a' = true, b' = b, result' = result,
  }

  // Today: lock b, re-read, write, yield.  #656: rename b and return.
  action writeB = all {
    phase == "aDone",
    phase' = if (fix656) "done" else "bDone", a' = a, b' = true,
    result' = if (fix656) "ok" else result,
  }

  action ret = all {
    phase == "bDone",
    phase' = "done", a' = a, b' = b, result' = "ok",
  }

  // Cancel at a yield: between files today; only while staging with #656.
  def cancellable: bool =
    if (fix656) Set("pre", "staged").contains(phase)
    else Set("pre", "aDone", "bDone").contains(phase)

  action cancel = all {
    cancellable,
    phase' = "done", a' = a, b' = b, result' = "cancelled",
  }

  action crash = all {
    Set("pre", "staged", "aDone", "bDone").contains(phase),
    phase' = "done", a' = a, b' = b, result' = "crashed",
  }

  action stutter = all {
    phase == "done",
    phase' = phase, a' = a, b' = b, result' = result,
  }

  action step = any { start, writeA, stage, renameA, writeB, ret, cancel, crash, stutter }

  // A batch that returns (ok or cancelled) applied all files or none.
  val batchAllOrNothing =
    Set("ok", "cancelled").contains(result) implies a == b

  // G2: a cancelled batch changed nothing.
  val cancelledMeansUnchanged = result == "cancelled" implies not(a or b)

  // An ok batch applied every file.
  val okMeansAll = result == "ok" implies (a and b)

  // G5: a crash leaves all files or none.  Not provided.
  val batchCrashAtomic = result == "crashed" implies a == b

  val inductiveInv = and {
    phase.in(Set("idle", "pre", "staged", "aDone", "bDone", "done")),
    a.in(Set(true, false)), b.in(Set(true, false)),
    result.in(Set("none", "ok", "cancelled", "crashed")),
    batchAllOrNothing, cancelledMeansUnchanged, okMeansAll,
    (phase != "done") iff (result == "none"),
    Set("idle", "pre", "staged").contains(phase) implies not(a or b),
    phase == "aDone" implies (a and not(b)),
    phase != "bDone",
    b implies a,
  }
}

module current { import multiFileCommit(FIXES = Set("656")).* }
module fixed { import multiFileCommit(FIXES = Set("656")).* }
