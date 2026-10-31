// Deterministic witnesses for the rotation proof model (quint test).
// The w611-w613 counterexamples against `current` were retired in #605, when
// the code gained the fixes: their traces need actions the fixed design
// disables (a second POST under the lock, logout during a refresh, a cancel
// after commit); the reach...Test runs below cover the fixed behaviour.
module witnesses {
  import rotation(FIXES = Set("611", "612", "613")) as F from "./model"
  import rotation(FIXES = Set("612")) as F612 from "./model"
  import rotation(FIXES = Set("611", "612")) as N613 from "./model"

  // Ghost sanity check (formerly w613NotExcusedAfterRecoveryTest), on a
  // design without fix 613: the excuse for an inherent loss is scoped to the
  // lost generation and cleared by the login, so a later cancel after commit
  // is caught.
  run ghostLossNotStickyTest =
    N613::init.then(N613::begin(1)).then(N613::serve(1)).then(N613::transportLoss(1))
      .expect(N613::storeRefreshable and N613::lost.get(0))
      .then(N613::login).then(N613::begin(1)).then(N613::serve(1)).then(N613::cancel(1))
      .expect(not(N613::storeRefreshable) and N613::gen == 2 and not(N613::lost.get(2)))

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
