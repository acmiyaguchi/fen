// Deterministic witnesses (quint test). Each reach...Test shows a fixed
// behaviour the invariants rely on is reachable (no vacuous pass).
// The w611-w616 counterexamples against `current` were retired in #605, when
// the code gained all six fixes: their traces now need actions the fixed
// design disables (a second POST while the lock is held, logout during a
// refresh, a cancel after commit, a request with an expired token), and the
// fixed behaviour on each is covered by the reach...Test runs below.
module witnesses {
  import auth(FIXES = Set("611", "612", "613", "614", "615", "616")) as C from "./model"
  import auth(FIXES = Set("611", "612", "613", "614", "615", "616")) as F from "./model"
  import auth(FIXES = Set("612")) as F612 from "./model"
  import auth(FIXES = Set("611", "612", "614", "615", "616")) as N613 from "./model"

  // Ghost sanity check (formerly w613NotExcusedAfterRecoveryTest), on a
  // design without fix 613: a transport loss excuses R0 only while the store
  // holds R0; after a fresh login a cancel after commit is caught again.
  // With the old sticky `inherentLoss` ghost this trace would pass.
  run ghostLossNotStickyTest =
    N613::init.then(N613::tick).then(N613::begin(1, false)).then(N613::responseLost(1))
      .expect(N613::storeRefreshable and N613::g.lost == Set(0))
      .then(N613::login).then(N613::tick).then(N613::begin(1, false)).then(N613::cancel(1, true))
      .expect(and {
        not(N613::storeRefreshable),
        N613::store == { present: true, gen: 2 },
        N613::g.lost == Set(),
      })

  // #615 regression (formerly w615TmpWorldReadableTest): in today's code the
  // tmp file holding the new tokens is private from creation, also when a
  // crash leaves it behind.
  run reachTmpPrivateThroughCrashTest =
    C::init.then(C::tick).then(C::begin(1, true)).then(C::respond(1)).then(C::writeTmp(1))
      .expect(C::secretsPrivate)
      .then(C::crash(1))
      .expect(C::secretsPrivate and C::allInvariants)

  // ---- reachability of the fixed design ----

  // A refresh completes, persists, and pins the new token.
  run reachRefreshPersistsTest =
    F::init.then(F::tick).then(F::begin(1, true)).then(F::respond(1))
      .then(F::writeTmp(1)).then(F::rename(1))
      .expect(and {
        F::store == { present: true, gen: 1 },
        F::procs.get(1).pinned == 1,
        F::authLock == 0,
        F::allInvariants,
      })

  // While one process refreshes, the other waits for the lock; afterwards
  // it finds the new, live token and does not POST.
  run reachSecondProcessWaitsTest =
    F::init.then(F::tick).then(F::begin(1, false))
      .expect(F::authLock == 1)  // begin(2) needs the lock to POST
      .then(F::respond(1)).then(F::writeTmp(1)).then(F::rename(1))
      .then(F::begin(2, false))
      .expect(F::procs.get(2).phase == "idle" and F::allInvariants)

  // A cancel before the server processed the POST loses nothing, and the
  // cancel after commit is deferred (shielded).
  run reachCancelBeforeCommitTest =
    F::init.then(F::tick).then(F::begin(1, false))
      .expect(F::F613)  // cancel(1, true) is disabled under fix 613
      .then(F::cancel(1, false))
      .expect(F::store == { present: true, gen: 0 } and F::authLock == 0 and F::allInvariants)

  // Logout waits for an in-flight refresh, then removes the record for good.
  run reachLogoutAfterRefreshTest =
    F::init.then(F::tick).then(F::begin(1, false))
      .expect(F::authLock == 1)  // logout needs the lock
      .then(F::respond(1)).then(F::writeTmp(1)).then(F::rename(1))
      .then(F::logout)
      .expect(not(F::store.present) and F::g.loggedOut and F::allInvariants)

  // Fix 612 alone (no lock): the stale refresh's rename is dropped.
  run reachStaleRenameDroppedTest =
    F612::init.then(F612::tick).then(F612::begin(1, false)).then(F612::logout)
      .then(F612::respond(1)).then(F612::writeTmp(1)).then(F612::rename(1))
      .expect(not(F612::store.present) and F612::noResurrection)

  // A transport loss after commit is excused while the store holds R0;
  // login recovers and clears the excuse.
  run reachInherentLossThenLoginTest =
    F::init.then(F::tick).then(F::begin(1, false)).then(F::responseLost(1))
      .expect(F::g.lost == Set(0) and F::allInvariants)
      .then(F::login)
      .expect(F::g.lost == Set() and F::usable and F::allInvariants)

  // An expired token is not sent; it is refreshed and the request then goes
  // out with the new token (reachable, not a liveness claim).
  run reachExpiryRefreshThenRequestTest =
    F::init.then(F::begin(1, true)).then(F::tick)
      .expect(not(F::srv.live.contains(F::store.gen)))  // request(1) is disabled
      .then(F::begin(1, false)).then(F::respond(1)).then(F::writeTmp(1)).then(F::rename(1))
      .then(F::request(1))
      .expect(F::lastAction == "requestOk" and F::allInvariants)

  // A 429 recorded during the GET survives the GET's return.
  run reach429DuringGetKeptTest =
    F::init.then(F::qSendGet).then(F::qExhaust).then(F::q429).then(F::qReturn)
      .expect(F::q.shown == "exhausted" and F::q.get == "none" and F::allInvariants)

  // A GET with no 429 meanwhile still updates the shown quota.
  run reachGetUpdatesTest =
    F::init.then(F::qExhaust).then(F::qSendGet).then(F::qReturn)
      .expect(F::q.shown == "exhausted" and F::q.fresh and F::allInvariants)
}
