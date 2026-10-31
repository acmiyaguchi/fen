// Proof model: OAuth refresh-token rotation with two clients, logout, login,
// and cancellation. Only the state this contract needs:
//
//   server   valid[k]: the token endpoint accepts refresh token k. Using a
//            valid k invalidates it and issues k' (single-use rotation);
//            reusing an invalidated one fails (invalid_grant).
//   store    auth.json: present + the refresh generation it holds.
//   client   phase per process:
//              idle -> posting   auth.json read and its refresh token
//                                POSTed (fix 611: inside the auth lock)
//              posting -> srv    the server committed the rotation; the
//                                response is in flight
//              srv -> got        the response was consumed: new tokens in
//                                memory
//              got -> idle       persisted (tmp + rename)
//
// Access-token expiry is not modelled: every refresh is assumed needed, the
// worst case for rotation. Generations are drawn from a constant domain
// GENS; issuing stops when it is exhausted (a bound on the number of
// rotations and logins, not on depth: the inductive obligations cover every
// state of that domain).
//
// FIXES (same numbering as ../../model.qnt):
//   611  POST only under the auth lock, re-reading the record inside it, and
//        re-read the record after a failed POST
//   612  persist only if the record still carries the token that was used
//   613  a cancel after the server committed is deferred until persisted
module rotation {
  const FIXES: Set[str]

  pure val PROCS = Set(1, 2)
  pure val G = 4
  pure val GENS = 0.to(G - 1)
  pure val PHASES = Set("idle", "posting", "srv", "got")

  val F611 = FIXES.contains("611")
  val F612 = FIXES.contains("612")
  val F613 = FIXES.contains("613")

  var valid: int -> bool
  var nextGen: int
  var present: bool
  var gen: int
  var phase: int -> str
  var used: int -> int
  var got: int -> int
  var lock: int
  // ghosts
  var loggedOut: bool
  var rejectedUsable: bool
  var lost: int -> bool   // generations whose rotation was lost inherently
  var lastAction: str

  action init = all {
    valid' = GENS.mapBy(k => k == 0),
    nextGen' = 1,
    present' = true,
    gen' = 0,
    phase' = PROCS.mapBy(_ => "idle"),
    used' = PROCS.mapBy(_ => 0),
    got' = PROCS.mapBy(_ => 0),
    lock' = 0,
    loggedOut' = false,
    rejectedUsable' = false,
    lost' = GENS.mapBy(_ => false),
    lastAction' = "init",
  }

  val usable = present and valid.get(gen)
  def inflight(p: int): bool = Set("posting", "srv", "got").contains(phase.get(p))
  def afterCommit(p: int): bool = phase.get(p) == "srv" or phase.get(p) == "got"

  action keepSrv = all { valid' = valid, nextGen' = nextGen }
  action keepStore = all { present' = present, gen' = gen }
  action keepGhost = all { loggedOut' = loggedOut, rejectedUsable' = rejectedUsable, lost' = lost }

  // get-fresh-creds! reads auth.json and POSTs its refresh token (no yield
  // between the two). Fix 611 does both inside the auth lock, so the record
  // it refreshes is the one current when the lock was taken.
  action begin(p: int): bool = all {
    phase.get(p) == "idle", present,
    not(F611) or lock == 0,
    phase' = phase.set(p, "posting"), used' = used.set(p, gen),
    lock' = if (F611) p else lock,
    got' = got, keepSrv, keepStore, keepGhost,
    lastAction' = "begin",
  }

  def release(p: int): int = if (lock == p) 0 else lock

  // The token endpoint processes the POST: rotation, or invalid_grant.
  action serve(p: int): bool = all {
    phase.get(p) == "posting",
    val k = used.get(p)
    if (valid.get(k))
      all {
        nextGen < G,
        valid' = valid.set(k, false).set(nextGen, true), nextGen' = nextGen + 1,
        phase' = phase.set(p, "srv"), got' = got.set(p, nextGen), lock' = lock,
        rejectedUsable' = rejectedUsable,
        lastAction' = "rotate",
      }
    else
      // Fix 611 re-reads auth.json after the failure and uses a valid
      // record another process wrote, so only a real failure is reported.
      all {
        keepSrv, phase' = phase.set(p, "idle"), got' = got, lock' = release(p),
        rejectedUsable' = (rejectedUsable or (usable and not(F611))),
        lastAction' = "rejected",
      },
    used' = used, keepStore, loggedOut' = loggedOut, lost' = lost,
  }

  action receive(p: int): bool = all {
    phase.get(p) == "srv",
    phase' = phase.set(p, "got"),
    used' = used, got' = got, lock' = lock, keepSrv, keepStore, keepGhost,
    lastAction' = "receive",
  }

  // storage.set: load, modify, save. Fix 612 writes only if the record still
  // carries the refresh token that was used.
  action persist(p: int): bool = all {
    phase.get(p) == "got",
    val writes = not(F612) or (present and gen == used.get(p))
    all {
      present' = if (writes) true else present,
      gen' = if (writes) got.get(p) else gen,
    },
    phase' = phase.set(p, "idle"), lock' = release(p),
    used' = used, got' = got, keepSrv, keepGhost,
    lastAction' = "persist",
  }

  // Cooperative cancel at the http yield. Before the server committed nothing
  // is lost. After it did, today the new tokens are dropped; fix 613 defers
  // the cancel until the result is persisted.
  action cancel(p: int): bool = all {
    phase.get(p) == "posting" or (phase.get(p) == "srv" and not(F613)),
    phase' = phase.set(p, "idle"), lock' = release(p),
    used' = used, got' = got, keepSrv, keepStore, keepGhost,
    lastAction' = if (phase.get(p) == "srv") "cancelAfterCommit" else "cancelBeforeCommit",
  }

  // Transport loss after the server committed: no client can recover.
  action transportLoss(p: int): bool = all {
    phase.get(p) == "srv",
    phase' = phase.set(p, "idle"), lock' = release(p),
    lost' = lost.set(used.get(p), true),
    used' = used, got' = got, keepSrv, keepStore,
    loggedOut' = loggedOut, rejectedUsable' = rejectedUsable,
    lastAction' = "transportLoss",
  }

  // Process death; the kernel drops its lock. After commit the rotation is
  // lost (inherent).
  action crash(p: int): bool = all {
    phase.get(p) != "idle",
    phase' = phase.set(p, "idle"), lock' = release(p),
    lost' = if (afterCommit(p)) lost.set(used.get(p), true) else lost,
    used' = used, got' = got, keepSrv, keepStore,
    loggedOut' = loggedOut, rejectedUsable' = rejectedUsable,
    lastAction' = "crash",
  }

  // fen --logout (local only).
  action logout = all {
    present,
    present' = false, loggedOut' = true,
    gen' = gen, phase' = phase, used' = used, got' = got, lock' = lock, keepSrv,
    rejectedUsable' = rejectedUsable, lost' = lost,
    lastAction' = "logout",
  }

  // fen --login: a new token family; the recovery from a lost rotation.
  action login = all {
    nextGen < G,
    valid' = valid.set(nextGen, true), nextGen' = nextGen + 1,
    present' = true, gen' = nextGen,
    loggedOut' = false, lost' = GENS.mapBy(_ => false),
    phase' = phase, used' = used, got' = got, lock' = lock,
    rejectedUsable' = rejectedUsable,
    lastAction' = "login",
  }

  action step = any {
    nondet p = PROCS.oneOf()
    any { begin(p), serve(p), receive(p), persist(p), cancel(p), transportLoss(p), crash(p) },
    logout, login,
  }

  // ---- properties ----

  // At most one refresh is between POST and persist across processes.
  val singleRefreshInFlight = PROCS.filter(p => inflight(p)).size() <= 1

  // A refresh is reported failed only when the store holds no valid token.
  val noRefreshRejectedWhileUsable = not(rejectedUsable)

  // After logout nothing writes credentials back until the nextGen login.
  val noResurrection = loggedOut implies not(present)

  // The store never holds only a revoked refresh token, unless a client
  // still holds its successor and will write it, or that generation's
  // rotation was lost inherently (scoped to the generation; login clears it).
  val storeRefreshable =
    not(present) or valid.get(gen) or lost.get(gen)
      or PROCS.exists(p => afterCommit(p) and valid.get(got.get(p)) and used.get(p) == gen)

  val allInvariants = and {
    singleRefreshInFlight, noRefreshRejectedWhileUsable, noResurrection, storeRefreshable,
  }

  // ---- inductive strengthening (fixed) ----

  val typeOk = and {
    valid.in(GENS.setOfMaps(Set(true, false))),
    lost.in(GENS.setOfMaps(Set(true, false))),
    nextGen.in(1.to(G)),
    present.in(Set(true, false)),
    gen.in(GENS),
    phase.in(PROCS.setOfMaps(PHASES)),
    used.in(PROCS.setOfMaps(GENS)),
    got.in(PROCS.setOfMaps(GENS)),
    lock.in(Set(0).union(PROCS)),
    loggedOut.in(Set(true, false)),
    rejectedUsable.in(Set(true, false)),
    lastAction.in(Set("init", "begin", "rotate", "rejected", "receive", "persist",
                      "cancelAfterCommit", "cancelBeforeCommit", "transportLoss", "crash",
                      "logout", "login")),
  }

  // The lock is held exactly by the process between POST and persist.
  val lockOwnsInflight = PROCS.forall(p => inflight(p) iff lock == p)

  // Nothing at or above `nextGen` has been issued; the store and clients only
  // refer to issued tokens; a client past the commit holds a valid successor
  // that nobody else can spend (it is not in the store until persisted).
  val issued = and {
    GENS.forall(k => k >= nextGen implies not(valid.get(k))),
    gen < nextGen,
    PROCS.forall(p => used.get(p) < nextGen and got.get(p) < nextGen),
    PROCS.forall(p => afterCommit(p) implies (valid.get(got.get(p)) and got.get(p) != gen)),
  }

  val rotationInductive = and {
    typeOk, lockOwnsInflight, issued, allInvariants,
  }

  // Fix 611 alone: the lock gives single flight; the re-read after a failed
  // POST gives no spurious failure.
  val lockInductive = and {
    typeOk, lockOwnsInflight, singleRefreshInFlight, noRefreshRejectedWhileUsable,
  }

  // Fix 612 alone: logout's guarantee needs no strengthening.
  val resurrectionInductive = typeOk and noResurrection
}

// Since #605 today's code carries the fixes, so `current` matches `fixed`.
module current { import rotation(FIXES = Set("611", "612", "613")).* }
module fixed { import rotation(FIXES = Set("611", "612", "613")).* }
module fix611 { import rotation(FIXES = Set("611")).* }
module fix612 { import rotation(FIXES = Set("612")).* }
module fix613 { import rotation(FIXES = Set("613")).* }
