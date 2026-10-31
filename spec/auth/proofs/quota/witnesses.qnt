// Deterministic witnesses for the quota proof model (quint test).
// The w616 counterexample against `current` was retired in #605, when the
// usage GET started keeping limits recorded while it was in flight; it is
// the same trace as reach429DuringGetKeptTest below.
module witnesses {
  import quota(FIXES = Set("616")) as F from "./model"

  // ---- reachability of the fixed design ----

  // The 429 survives the GET that was in flight.
  run reach429DuringGetKeptTest =
    F::init.then(F::sendGet).then(F::exhaust).then(F::rec429).then(F::getReturn)
      .expect(F::shown == "exhausted" and F::sampled == "none" and F::quotaInductive)

  // A GET with no 429 meanwhile still updates the shown quota.
  run reachGetUpdatesTest =
    F::init.then(F::exhaust).then(F::sendGet).then(F::getReturn)
      .expect(F::shown == "exhausted" and F::fresh and F::quotaInductive)

  // A GET that sampled exhaustion but returns after the reset shows 100%.
  run reachResetDuringGetTest =
    F::init.then(F::exhaust).then(F::sendGet).then(F::reset).then(F::getReturn)
      .expect(F::shown == "avail" and not(F::server) and F::quotaInductive)
}
