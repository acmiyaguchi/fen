// Deterministic witnesses (quint test). Each w<issue>...Test replays that
// issue's counterexample against `current` and pins it with a state predicate
// so the row cannot stay violated for a different bug; each reach...Test shows
// a fixed behaviour the invariants rely on is reachable (no vacuous pass).
module witnesses {
  import auth(FIXES = Set()) as C from "./model"
  import auth(FIXES = Set("611", "612", "613", "614", "615", "616")) as F from "./model"
  import auth(FIXES = Set("612")) as F612 from "./model"

  // #611: both processes read R0 and POST it; the first rotates and writes
  // R1, the second is rejected although auth.json now holds the valid R1.
  // Pinned to #611: no pinned request, no cancel, no logout in the trace, and
  // the failure is the refresh rejection itself.
  run w611ConcurrentRefreshLoserFailsTest =
    C::init.then(C::tick).then(C::begin(1, false)).then(C::begin(2, false))
      .expect(not(C::singleRefreshInFlight))
      .then(C::respond(1)).then(C::writeTmp(1)).then(C::rename(1))
      .then(C::respond(2))
      .expect(and {
        not(C::noRefreshRejectedWhileUsable),
        C::lastAction == "refreshRejected",
        C::store == { present: true, gen: 1 },
        C::srv.valid.contains(1),
        C::noExpiredTokenRequest,
        C::g.lost == Set(),
      })

  // #612: a refresh that began before logout writes the record back.
  run w612RefreshResurrectsAfterLogoutTest =
    C::init.then(C::tick).then(C::begin(1, false)).then(C::logout)
      .then(C::respond(1)).then(C::writeTmp(1)).then(C::rename(1))
      .expect(and {
        not(C::noResurrection),
        C::g.loggedOut, C::store.present, C::lastAction == "rename",
      })

  // #613: a cancel after the server committed the rotation drops R1, and
  // auth.json keeps the revoked R0; nothing inherent happened.
  run w613CancelAfterCommitLosesRotationTest =
    C::init.then(C::tick).then(C::begin(1, true)).then(C::cancel(1, true))
      .expect(and {
        not(C::storeRefreshable),
        C::g.lost == Set(),
        C::store == { present: true, gen: 0 },
        not(C::srv.valid.contains(0)),
      })

  // #613 is not excused by an earlier, unrelated inherent loss: a transport
  // loss excuses R0 only while the store holds R0; after a fresh login the
  // same cancel bug is caught again. (With the old sticky `inherentLoss`
  // ghost this trace would pass.)
  run w613NotExcusedAfterRecoveryTest =
    C::init.then(C::tick).then(C::begin(1, false)).then(C::responseLost(1))
      .expect(C::storeRefreshable and C::g.lost == Set(0))
      .then(C::login).then(C::tick).then(C::begin(1, false)).then(C::cancel(1, true))
      .expect(and {
        not(C::storeRefreshable),
        C::store == { present: true, gen: 2 },
        C::g.lost == Set(),
      })

  // #614: the access token pinned at startup expires; the next request
  // carries it and gets a terminal 401 while auth.json is refreshable.
  run w614PinnedTokenExpires401Test =
    C::init.then(C::begin(1, true)).then(C::tick).then(C::request(1))
      .expect(and {
        not(C::noExpiredTokenRequest),
        C::lastAction == "request401",
        C::noRefreshRejectedWhileUsable,
        C::usable,
      })

  // #615: the tmp file holds the new tokens before its chmod, and a crash
  // at that point leaves it behind.
  run w615TmpWorldReadableTest =
    C::init.then(C::tick).then(C::begin(1, true)).then(C::respond(1)).then(C::writeTmp(1))
      .expect(not(C::secretsPrivate) and not(C::leakedTmp))
      .then(C::crash(1))
      .expect(not(C::secretsPrivate) and C::leakedTmp)

  // #616: a 429 recorded while the usage GET is in flight is overwritten
  // by the GET's older sample, shown as fresh.
  run w616GetOverwrites429Test =
    C::init.then(C::qSendGet).then(C::qExhaust).then(C::q429)
      .expect(C::q.shown == "exhausted")
      .then(C::qReturn)
      .expect(and {
        not(C::quotaFreshNotContradicted),
        C::q.shown == "avail", C::q.fresh, C::q.server,
      })

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
