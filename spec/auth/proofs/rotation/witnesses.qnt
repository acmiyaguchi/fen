// Deterministic witnesses for the rotation proof model (quint test).
module witnesses {
  import rotation(FIXES = Set()) as C from "./model"
  import rotation(FIXES = Set("611", "612", "613")) as F from "./model"
  import rotation(FIXES = Set("612")) as F612 from "./model"

  // #611: both clients POST R0; the first rotates and persists R1, the
  // second is rejected while auth.json holds the valid R1.
  run w611ConcurrentRefreshLoserFailsTest =
    C::init.then(C::begin(1)).then(C::begin(2))
      .expect(not(C::singleRefreshInFlight))
      .then(C::serve(1)).then(C::receive(1)).then(C::persist(1))
      .then(C::serve(2))
      .expect(and {
        not(C::noRefreshRejectedWhileUsable),
        C::lastAction == "rejected",
        C::present, C::gen == 1, C::valid.get(1),
      })

  // #612: a refresh that began before logout persists afterwards.
  run w612RefreshResurrectsAfterLogoutTest =
    C::init.then(C::begin(1)).then(C::logout)
      .then(C::serve(1)).then(C::receive(1)).then(C::persist(1))
      .expect(not(C::noResurrection) and C::loggedOut and C::present)

  // #613: a cancel after the server committed drops R1; auth.json keeps the
  // revoked R0 and nothing inherent excuses it.
  run w613CancelAfterCommitLosesRotationTest =
    C::init.then(C::begin(1)).then(C::serve(1)).then(C::cancel(1))
      .expect(and {
        not(C::storeRefreshable),
        C::lastAction == "cancelAfterCommit",
        C::gen == 0, not(C::valid.get(0)), not(C::lost.get(0)),
      })

  // #613 after an earlier inherent loss and a login: the excuse is scoped to
  // the lost generation and cleared by the login, so the bug is caught.
  run w613NotExcusedAfterRecoveryTest =
    C::init.then(C::begin(1)).then(C::serve(1)).then(C::transportLoss(1))
      .expect(C::storeRefreshable and C::lost.get(0))
      .then(C::login).then(C::begin(1)).then(C::serve(1)).then(C::cancel(1))
      .expect(not(C::storeRefreshable) and C::gen == 2 and not(C::lost.get(2)))

  // ---- reachability of the fixed design ----

  // Both clients refresh one after the other: the second waits for the
  // lock, then rotates the token the first persisted.
  run reachSequentialRefreshesTest =
    F::init.then(F::begin(1))
      .expect(F::lock == 1 and F::phase.get(2) == "idle")
      .then(F::serve(1)).then(F::receive(1)).then(F::persist(1))
      .then(F::begin(2)).then(F::serve(2)).then(F::receive(2)).then(F::persist(2))
      .expect(F::gen == 2 and F::valid.get(2) and F::lock == 0 and F::rotationInductive)

  // A cancel before commit, then a successful refresh.
  run reachCancelBeforeCommitTest =
    F::init.then(F::begin(1)).then(F::cancel(1)).then(F::begin(2)).then(F::serve(2))
      .then(F::receive(2)).then(F::persist(2))
      .expect(F::gen == 1 and F::rotationInductive)

  // Logout and login while a refresh is in flight: the stale result is
  // dropped, the new login stays.
  run reachLoginDuringRefreshTest =
    F::init.then(F::begin(1)).then(F::logout).then(F::login).then(F::serve(1))
      .then(F::receive(1)).then(F::persist(1))
      .expect(F::present and F::gen == 1 and F::valid.get(1) and F::rotationInductive)

  // Fix 612 alone: logout during a refresh stays logged out.
  run reachLogoutDuringRefreshTest =
    F612::init.then(F612::begin(1)).then(F612::logout).then(F612::serve(1))
      .then(F612::receive(1)).then(F612::persist(1))
      .expect(not(F612::present) and F612::resurrectionInductive)

  // A crash after commit is excused for the lost generation only.
  run reachCrashAfterCommitTest =
    F::init.then(F::begin(1)).then(F::serve(1)).then(F::receive(1)).then(F::crash(1))
      .expect(F::lost.get(0) and F::lock == 0 and F::rotationInductive)
      .then(F::login)
      .expect(not(F::lost.get(0)) and F::rotationInductive)

  // A client whose refresh was rejected (store holds a revoked token after a
  // transport loss) reports the failure; that is not a spurious one.
  run reachRealRejectionTest =
    F::init.then(F::begin(1)).then(F::serve(1)).then(F::transportLoss(1))
      .then(F::begin(2)).then(F::serve(2))
      .expect(F::lastAction == "rejected" and F::rotationInductive)
}
