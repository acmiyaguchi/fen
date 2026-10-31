// Deterministic witnesses for the file-commit proof model.
module witnesses {
  import fileCommit(FIXES = Set()) as C from "./model"
  import fileCommit(FIXES = Set("654", "655", "656", "657")) as F from "./model"

  // #654: the first chunk truncates the target in place.
  run w654FirstChunkTearsTargetTest =
    C::init.then(C::startWith(false)).then(C::chunk1)
      .expect(not(C::noTornTarget) and C::result == "none")

  // #655: a failed chunk is ignored; ok with a torn file.
  run w655FailedWriteReportsOkTest =
    C::init.then(C::startWith(true)).then(C::chunk1).then(C::chunk2)
      .then(C::close).then(C::commit).then(C::ret)
      .expect(not(C::okMeansWritten) and C::disk == "part")

  // #656: the yield after the commit turns a completed write into
  // "cancelled".
  run w656CancelAfterCommitTest =
    C::init.then(C::startWith(false)).then(C::chunk1).then(C::chunk2)
      .then(C::close).then(C::commit).then(C::cancel)
      .expect(not(C::cancelledMeansUnchanged) and C::disk == "new")

  // #657: an outside write after the read is reverted.
  run w657OutsideWriteRevertedTest =
    C::init.then(C::startWith(false)).then(C::outsideWrite).then(C::chunk1)
      .expect(not(C::outsideLossOnlyInWindow) and C::noLostFenUpdate)

  // #657: so is a sibling fen process's commit.
  run w657FenWriteRevertedTest =
    C::init.then(C::startWith(false)).then(C::fenWrite).then(C::chunk1)
      .expect(not(C::noLostFenUpdate))

  // #657 (residual in the target design): an outside write between the check
  // and the rename is lost, and the call reports ok.
  run w657FixedCheckRenameWindowTest =
    F::init.then(F::startWith(false)).then(F::chunk1).then(F::chunk2)
      .then(F::close).then(F::check).then(F::outsideWrite).then(F::rename)
      .expect(not(F::noLostUpdate) and F::guarantees and F::result == "ok")

  // ---- reachability of the target design ----

  run reachOkTest =
    F::init.then(F::startWith(false)).then(F::chunk1).then(F::chunk2)
      .then(F::close).then(F::check).then(F::rename)
      .expect(F::result == "ok" and F::disk == "new" and F::inductiveInv)

  run reachIoErrorTest =
    F::init.then(F::startWith(true)).then(F::chunk1).then(F::chunk2).then(F::close)
      .expect(F::result == "error" and F::disk == "orig" and F::inductiveInv)

  run reachCancelMidWriteTest =
    F::init.then(F::startWith(false)).then(F::chunk1).then(F::cancel)
      .expect(F::result == "cancelled" and F::disk == "orig" and F::inductiveInv)

  // Detection: an outside write while the call yielded makes it fail.
  run reachDetectsOutsideWriteTest =
    F::init.then(F::startWith(false)).then(F::chunk1).then(F::outsideWrite)
      .then(F::chunk2).then(F::close).then(F::check)
      .expect(F::result == "error" and F::disk == "orig" and F::inductiveInv)

  // Serialization: with the lock held, a fen writer cannot run (fenWrite is
  // disabled throughout the call).
  run reachLockHeldTest =
    F::init.then(F::startWith(false)).then(F::chunk1)
      .expect(F::locks and F::active and F::inductiveInv)
}
