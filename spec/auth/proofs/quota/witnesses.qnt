// Deterministic witnesses for the quota proof model (quint test).
module witnesses {
  import quota(FIXES = Set()) as C from "./model"
  import quota(FIXES = Set("616")) as F from "./model"

  // #616: a 429 recorded while the GET is in flight is overwritten by the
  // GET's older sample, shown as fresh.
  run w616GetOverwrites429Test =
    C::init.then(C::sendGet).then(C::exhaust).then(C::rec429)
      .expect(C::shown == "exhausted" and C::obsSinceGet)
      .then(C::getReturn)
      .expect(and {
        not(C::quotaFreshNotContradicted),
        C::shown == "avail", C::fresh, C::server, C::obsNewer,
      })

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
