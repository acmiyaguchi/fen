// Abstract specification of durable store (#669): kernel lock plus atomic
// compare-and-rename.
//
// Refined and used by sessions (session lock, transcript append), auth (token
// rotation, credential store), and file tools (file edit/write commit).
//
// The contract:
// 1. A kernel lock provides mutual exclusion among writers. If a holder
//    crashes, the kernel releases the lock automatically.
// 2. Writes stage candidate content in a temporary location.
// 3. Commit is an atomic compare-and-rename: if the store still matches the
//    snapshot recorded when staging began, the target is replaced atomically.
//    If an outside write modified the store in the interim, the commit is
//    rejected (conflict detected) and the target is untouched.
// 4. Abort or cancel cleanly discards the staging without modifying the store.
//
// Pure definitions only, so concrete models can import them and check that
// their mapped state refines absNext.
module storeAbstract {
  type Abs = {
    holder: int,        // 0 = free, > 0 = process id holding kernel lock
    store: int,         // durable committed store value/generation
    staged: int,        // candidate value staged in temp (-1 if none)
    snap: int,          // snapshot version read when staging began (-1 if none)
    status: str,        // "idle" | "staged" | "committed" | "conflict" | "aborted"
  }

  pure val absInit: Abs = {
    holder: 0,
    store: 0,
    staged: -1,
    snap: -1,
    status: "idle",
  }

  // Acquire the kernel lock when free.
  pure def acquire(a: Abs, b: Abs): bool = and {
    a.holder == 0,
    b.holder > 0,
    b.store == a.store,
    b.staged == -1,
    b.snap == -1,
    b.status == "idle",
  }

  // Read snapshot and stage candidate value in temp.
  pure def stage(a: Abs, b: Abs): bool = and {
    a.holder > 0,
    a.staged == -1,
    b.holder == a.holder,
    b.store == a.store,
    b.snap == a.store,
    b.staged >= 0,
    b.status == "staged",
  }

  // Atomic compare-and-rename:
  // If store matches snapshot, replace store with staged value.
  // Otherwise, reject commit without touching the store (conflict detected).
  pure def commit(a: Abs, b: Abs): bool = and {
    a.holder > 0,
    a.status == "staged",
    b.holder == a.holder,
    b.staged == -1,
    b.snap == -1,
    if (a.snap == a.store)
      and { b.store == a.staged, b.status == "committed" }
    else
      and { b.store == a.store, b.status == "conflict" },
  }

  // Abort staging (e.g. error or cancellation before commit). Staging is discarded.
  pure def abort(a: Abs, b: Abs): bool = and {
    a.holder > 0,
    a.status == "staged",
    b.holder == a.holder,
    b.store == a.store,
    b.staged == -1,
    b.snap == -1,
    b.status == "aborted",
  }

  // Release the kernel lock.
  pure def release(a: Abs, b: Abs): bool = and {
    a.holder > 0,
    a.staged == -1,
    b.holder == 0,
    b.store == a.store,
    b.staged == -1,
    b.snap == -1,
    b.status == "idle",
  }

  // Crash: holder dies. Kernel automatically releases the lock and staging is discarded.
  pure def crash(a: Abs, b: Abs): bool = and {
    a.holder > 0,
    b.holder == 0,
    b.store == a.store,
    b.staged == -1,
    b.snap == -1,
    b.status == "idle",
  }

  // Outside write: external process modifies the store without the fen kernel lock.
  pure def outsideWrite(a: Abs, b: Abs): bool = and {
    b.holder == a.holder,
    b.store != a.store,
    b.staged == a.staged,
    b.snap == a.snap,
    b.status == a.status,
  }

  // Abstract step relation.
  pure def absNext(a: Abs, b: Abs): bool = or {
    a == b,
    acquire(a, b),
    stage(a, b),
    commit(a, b),
    abort(a, b),
    release(a, b),
    crash(a, b),
    outsideWrite(a, b),
  }

  // ---- properties every refining owner inherits ----

  // Staged temp content exists only while the kernel lock is held.
  pure def stagedRequiresLock(a: Abs): bool =
    a.staged != -1 implies a.holder != 0

  // Staging and snapshot are paired: staging always has a snapshot.
  pure def snapPairedWithStaged(a: Abs): bool =
    (a.staged == -1) == (a.snap == -1)

  // Unlocked state is clean: idle status, no staged write, no snapshot.
  pure def unlockedIsIdle(a: Abs): bool =
    a.holder == 0 implies (a.status == "idle" and a.staged == -1 and a.snap == -1)

  // Status and staging fields are mutually consistent.
  pure def statusConsistent(a: Abs): bool = and {
    a.status == "staged" implies a.staged != -1,
    Set("idle", "committed", "conflict", "aborted").contains(a.status) implies a.staged == -1,
  }

  pure def absInv(a: Abs): bool = and {
    stagedRequiresLock(a),
    snapPairedWithStaged(a),
    unlockedIsIdle(a),
    statusConsistent(a),
  }
}
