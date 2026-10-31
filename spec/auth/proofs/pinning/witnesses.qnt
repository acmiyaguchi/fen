// Deterministic witnesses for the pinning proof model (quint test).
module witnesses {
  import pinning(FIXES = Set()) as C from "./model"
  import pinning(FIXES = Set("614")) as F from "./model"

  // #614: the token pinned at construction expires; the next request
  // carries it (terminal 401) although auth.json can be refreshed.
  run w614PinnedTokenExpires401Test =
    C::init.then(C::build).then(C::request)
      .expect(C::lastAction == "requestOk" and C::noExpiredTokenRequest)
      .then(C::tick).then(C::request)
      .expect(not(C::noExpiredTokenRequest) and C::lastAction == "request401" and C::present)

  // #614 persists across a refresh by someone else: the store moves on, the
  // agent's pinned token does not.
  run w614PinnedSurvivesRefreshTest =
    C::init.then(C::build).then(C::tick).then(C::refresh).then(C::request)
      .expect(and {
        not(C::noExpiredTokenRequest), not(C::requestReadyWhenStoreLive),
        C::gen == 1, C::pinned == 0,
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
