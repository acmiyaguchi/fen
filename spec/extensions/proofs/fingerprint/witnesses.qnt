// Deterministic witnesses for the fingerprint proof model.
module witnesses {
  import fingerprint(FIXES = Set()) as C from "./model"
  import fingerprint(FIXES = Set("625")) as F from "./model"

  run reachRetryStillFailsTest =
    F::init.then(F::edit("bad")).then(F::reload).then(F::reload)
      .expect(F::status == "error" and not(F::committed) and F::fingerprintInductive)

  run reachRepairLoadsTest =
    F::init.then(F::edit("bad")).then(F::reload).then(F::edit("ok")).then(F::reload)
      .expect(F::status == "loaded" and F::committed and F::fingerprintInductive)
}
