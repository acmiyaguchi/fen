// Proof model: stale-lock reclaim in the JSONL backend's acquire-lock (#644).
//
//   extensions/adapters/session-backends/jsonl/session.fnl  acquire-lock:
//     mkdir lock; on failure read owner, kill -0, re-read owner, os.remove
//     owner, rmdir (result ignored), mkdir again; the winner writes its pid
//     afterwards.
//
// Two `fen session send` processes start while a dead owner (pid 9) holds the
// lock. State is only what mutual exclusion needs: the lock directory, the
// owner file, and each process's program counter and the owner it read.
//
// Fix #644: a lock the kernel releases when its holder dies (lfs.lock or
// flock on the transcript), so taking over a dead owner's lock is one atomic
// step and the reclaim sequence disappears.
module lock {
  const FIXES: Set[str]

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
      if (FIXES.contains("644"))
        // kernel lock: released on death, so takeover is one atomic step
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

  val holders = PROCS.filter(p => pc.get(p) == "own" or pc.get(p) == "hold")

  // At most one process believes it holds the session lock.
  val lockMutex = holders.size() <= 1

  // Inductive strengthening of lockMutex for the kernel-lock design: the
  // domain of every variable first (Apalache reads these as the initial
  // states of the induction step), then the facts the step needs. With the
  // kernel lock no process ever enters the reclaim states.
  val lockInductive = and {
    pc.in(setOfMaps(PROCS, Set("try", "read", "fail", "own", "hold", "done"))),
    seen.in(setOfMaps(PROCS, Set(0))),
    lockDir.in(Set(true, false)),
    owner.in(Set(0, DEAD, 1, 2)),
    lockMutex,
    holders.size() > 0 implies (lockDir and owner != DEAD),
    not(lockDir) implies owner == 0,
    PROCS.forall(p => pc.get(p) == "hold" implies owner == p),
    PROCS.forall(p => pc.get(p) == "own" implies owner == 0),
    PROCS.forall(p => owner == p implies pc.get(p) == "hold"),
  }
}

module lockCurrent { import lock(FIXES = Set()).* }
module lockFixed { import lock(FIXES = Set("644")).* }
