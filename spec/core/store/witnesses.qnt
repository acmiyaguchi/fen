// Reachability of the abstract store machine: each interesting way a store
// interaction can go actually happens, so the inductive proof is not vacuous.
module witnesses {
  import storeSpec as S from "./model"

  // Successful write cycle: acquire -> stage -> commit (ok) -> release.
  run reachCommitOkTest =
    S::init.then(S::doAcquire(1)).then(S::doStage(1)).then(S::doCommit)
      .then(S::doRelease)
      .expect(S::a.store == 1 and S::a.holder == 0 and S::allInvariants)

  // Conflict detected: outside write lands between stage and commit.
  run reachConflictDetectedTest =
    S::init.then(S::doAcquire(1)).then(S::doStage(1)).then(S::doOutsideWrite(2))
      .then(S::doCommit)
      .expect(S::a.status == "conflict" and S::a.store == 2 and S::allInvariants)

  // Abort discards staged content: store remains unchanged.
  run reachAbortTest =
    S::init.then(S::doAcquire(1)).then(S::doStage(1)).then(S::doAbort)
      .expect(S::a.status == "aborted" and S::a.store == 0 and S::allInvariants)

  // Crash releases the lock: process dies, kernel releases lock, store unchanged.
  run reachCrashReleasesLockTest =
    S::init.then(S::doAcquire(1)).then(S::doStage(1)).then(S::doCrash)
      .expect(S::a.holder == 0 and S::a.status == "idle" and S::a.store == 0 and S::allInvariants)

  // Alternating writers: process 1 writes, releases; process 2 acquires and writes.
  run reachAlternatingWritersTest =
    S::init.then(S::doAcquire(1)).then(S::doStage(1)).then(S::doCommit).then(S::doRelease)
      .then(S::doAcquire(2)).then(S::doStage(2)).then(S::doCommit).then(S::doRelease)
      .expect(S::a.store == 2 and S::a.holder == 0 and S::allInvariants)
}
