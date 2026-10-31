// Deterministic witnesses for the file-commit proof model.
module witnesses {
  import fileCommit(FIXES = Set("654", "655", "656", "657")) as C from "./model"
  import fileCommit(FIXES = Set("654", "655", "656", "657")) as F from "./model"






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
