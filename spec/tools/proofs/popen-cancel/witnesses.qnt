// Deterministic witnesses for the popen-cancel proof model.
module witnesses {
  import popenCancel(FIXES = Set()) as C from "./model"
  import popenCancel(FIXES = Set("659")) as F from "./model"

  // #659: cancel while the child still runs: pclose waits on it, unkilled.
  run w659CancelBlocksInPcloseTest =
    C::init.then(C::start).then(C::cancel)
      .expect(not(C::noUnboundedBlockingWait) and C::childAlive)

  run reachCompleteTest =
    F::init.then(F::start).then(F::childExit).then(F::eof)
      .expect(F::result == "ok" and F::inductiveInv)

  run reachCancelKillsTest =
    F::init.then(F::start).then(F::cancel).then(F::closeReturns)
      .expect(F::result == "cancelled" and F::killed and F::inductiveInv)
}
