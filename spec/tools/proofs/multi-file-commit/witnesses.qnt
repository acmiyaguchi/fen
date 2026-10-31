// Deterministic witnesses for the multi-file-commit proof model.
module witnesses {
  import multiFileCommit(FIXES = Set()) as C from "./model"
  import multiFileCommit(FIXES = Set("656")) as F from "./model"

  // #656: a cancel between the files leaves a written and reports cancelled.
  run w656CancelBetweenFilesTest =
    C::init.then(C::start).then(C::writeA).then(C::cancel)
      .expect(not(C::batchAllOrNothing) and not(C::cancelledMeansUnchanged))

  // #656 (residual under the fix): a crash between the renames.
  run w656FixedCrashBetweenRenamesTest =
    F::init.then(F::start).then(F::stage).then(F::renameA).then(F::crash)
      .expect(not(F::batchCrashAtomic) and F::batchAllOrNothing)

  run reachOkTest =
    F::init.then(F::start).then(F::stage).then(F::renameA).then(F::writeB)
      .expect(F::result == "ok" and F::inductiveInv)

  run reachCancelWhileStagingTest =
    F::init.then(F::start).then(F::stage).then(F::cancel)
      .expect(F::result == "cancelled" and F::inductiveInv)

  // No yield between the renames: cancel is disabled there.
  run reachNoCancelBetweenRenamesTest =
    F::init.then(F::start).then(F::stage).then(F::renameA)
      .expect(not(F::cancellable) and F::inductiveInv)

  run reachCrashBeforeRenamesTest =
    F::init.then(F::start).then(F::stage).then(F::crash)
      .expect(F::result == "crashed" and F::batchCrashAtomic)
}
