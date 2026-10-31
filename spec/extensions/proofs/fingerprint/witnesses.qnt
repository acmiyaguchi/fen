// Deterministic witnesses for the fingerprint proof model.
module witnesses {
  import fingerprint(FIXES = Set()) as C from "./model"
  import fingerprint(FIXES = Set("625")) as F from "./model"

  // #625: the failed reload commits the fingerprint; the next one skips the
  // broken module and reports the old code as :loaded.
  run w625FailedFingerprintCommittedTest =
    C::init.then(C::edit("bad")).then(C::reload).then(C::reload)
      .expect(not(C::loadedStatusTruthful) and C::status == "loaded" and C::src == "bad")

  run reachRetryStillFailsTest =
    F::init.then(F::edit("bad")).then(F::reload).then(F::reload)
      .expect(F::status == "error" and not(F::committed) and F::fingerprintInductive)

  run reachRepairLoadsTest =
    F::init.then(F::edit("bad")).then(F::reload).then(F::edit("ok")).then(F::reload)
      .expect(F::status == "loaded" and F::committed and F::fingerprintInductive)
}
