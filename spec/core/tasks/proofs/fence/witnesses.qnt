// Reachability for the fence: each case actually happens.
module witnesses {
  import fence as F from "./model"

  // A cancel addressed to the current holder arms it.
  run reachCancelCurrentTest =
    F::init.then(F::doAcquire(0)).then(F::doBodyStart(0)).then(F::doCancel(0, 1))
      .expect(F::armed.get(0) and F::allInvariants)

  // A cancel captured during run 1 lands during run 2 and is dropped.
  run reachStaleCancelDroppedTest =
    F::init.then(F::doAcquire(0)).then(F::doRelease(0)).then(F::doAcquire(0)).then(F::doCancel(0, 1))
      .expect(not(F::armed.get(0)) and F::hid.get(0) == 2 and F::allInvariants)

  // A cancel that lands between acquire and body start survives the start.
  run reachCancelBeforeBodyStartKeptTest =
    F::init.then(F::doAcquire(0)).then(F::doCancel(0, 1)).then(F::doBodyStart(0))
      .expect(F::armed.get(0) and F::allInvariants)

  // Two owners with the same id: a cancel for one leaves the other alone.
  run reachOwnersIndependentTest =
    F::init.then(F::doAcquire(0)).then(F::doAcquire(1)).then(F::doCancel(1, 1))
      .expect(F::armed.get(1) and not(F::armed.get(0)) and F::allInvariants)

  // A cancel while idle arms nothing, and the next run starts unarmed.
  run reachIdleCancelIgnoredTest =
    F::init.then(F::doAcquire(0)).then(F::doRelease(0)).then(F::doCancel(0, 1)).then(F::doAcquire(0))
      .expect(not(F::armed.get(0)) and F::allInvariants)
}
