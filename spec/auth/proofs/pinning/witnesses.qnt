// Deterministic witnesses for the pinning proof model (quint test).
// The w614 counterexamples against `current` were retired in #605, when
// resolve-creds started resolving credentials per request.
module witnesses {
  import pinning(FIXES = Set("614")) as F from "./model"

  // #614 regression (formerly w614PinnedSurvivesRefreshTest): after expiry
  // and a refresh by someone else, the request carries the store's new token.
  run reachRefreshByOtherPickedUpTest =
    F::init.then(F::build).then(F::tick).then(F::refresh).then(F::request)
      .expect(and {
        F::noExpiredTokenRequest, F::requestReadyWhenStoreLive,
        F::gen == 1, F::lastAction == "requestOk",
      })

  // ---- reachability of the fixed design ----

  // Expiry, then refresh, then the request goes out with the new token
  // (reachable; not a liveness claim).
  run reachExpiryRefreshThenRequestTest =
    F::init.then(F::build).then(F::request).then(F::tick)
      .expect(not(F::live.get(F::gen)))  // request is disabled until a refresh
      .then(F::refresh).then(F::request)
      .expect(F::lastAction == "requestOk" and F::gen == 1 and F::pinningInductive)

  // A re-login is picked up by the next request without a rebuild.
  run reachLoginPickedUpTest =
    F::init.then(F::build).then(F::logout).then(F::login).then(F::request)
      .expect(F::lastAction == "requestOk" and F::gen == 1 and F::pinned == 0
              and F::pinningInductive)
}
