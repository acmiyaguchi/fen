// Deterministic witnesses for the reload phase/atomicity proof model.
module witnesses {
  import reload(FIXES = Set()) as B from "./model"
  import reload(FIXES = Set("early", "atomic")) as F from "./model"

  // ---- counterexamples in the pre-fix design (`before`) ----

  // Ctrl-C during the core pass is honored at :after-core: core new, extension old.
  run wBeforeCancelAfterCoreMixTest =
    B::init.then(B::request(false)).then(B::advance("none")).then(B::advance("none"))
      .then(B::advance("none")).then(B::advance("none")).then(B::cancel)
      .then(B::advance("none")).then(B::advance("none"))
      .expect(B::outcome == "cancelled" and B::c1 == 1 and B::ext == 0
              and not(B::cancelLeavesOld) and not(B::mixTracked))

  // Ctrl-C right after `/reload --recover registries` started: buckets stay cleared.
  run wBeforeCancelAfterRecoverTest =
    B::init.then(B::request(true)).then(B::cancel).then(B::advance("none"))
      .then(B::advance("none")).then(B::advance("none"))
      .expect(B::outcome == "cancelled" and B::registries == "cleared"
              and not(B::registriesNotLost))

  // ---- reachability of the fixed design ----

  // A cancel before the first phase step: nothing ran.
  run reachCancelBeforeSwapTest =
    F::init.then(F::request(true)).then(F::cancel).then(F::advance("none"))
      .expect(F::outcome == "cancelled" and F::allOld and F::registries == "live"
              and not(F::holder) and F::reloadInductive)

  // A cancel during the core pass is not honored: the reload completes.
  run reachCancelMidSwapCompletesTest =
    F::init.then(F::request(true)).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("none")).then(F::cancel)
      .then(F::advance("none")).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("none")).then(F::advance("none"))
      .expect(F::outcome == "ok" and F::allNew and F::registries == "live"
              and not(F::holder) and F::reloadInductive)

  // A module execution error leaves a recorded mix and releases the holder.
  run reachFailedMixTrackedTest =
    F::init.then(F::request(false)).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("exec")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("none"))
      .expect(F::outcome == "failed" and F::mixed and F::dirty and not(F::holder)
              and F::reloadInductive)

  // An extension owner's failure rolls its registrations back with its module.
  run reachExtFailureRollsBackTest =
    F::init.then(F::request(false)).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("exec"))
      .expect(F::ext == 0 and F::regv == 0 and F::dirty and F::reloadInductive)

  // The agent rebuild raises after every swap: all new, holder released.
  run reachRaiseAfterSwapsTest =
    F::init.then(F::request(false)).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("none")).then(F::advance("none")).then(F::advance("none"))
      .then(F::advance("raise"))
      .expect(F::outcome == "raised" and F::allNew and not(F::holder)
              and F::reloadInductive)
}
