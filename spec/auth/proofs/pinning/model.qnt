// Proof model: provider credentials pinned at agent construction vs resolved
// per request (#614). Only the state this contract needs:
//
//   live[k]   access token k is unexpired (the clock expires all of them)
//   present, gen
//             auth.json holds access/refresh generation `gen`
//   pinned    the token the agent captured at construction (provider-options
//             .creds); NONE before the first build
//
// Refresh is atomic here (its races are the rotation model's subject): it
// replaces the stored record with a fresh, live generation. Generations come
// from the constant domain GENS; issuing stops when it is exhausted.
//
// FIXES: 614 resolves credentials per request: a request carries the stored
// token and goes out only while it is live, so an expired token must be
// refreshed first.
//
// What this proves is safety only: no request carries an expired token while
// the store has a usable credential, and a request is ready whenever the
// store holds a live token. It does not prove that, after expiry, a refresh
// happens and the request then proceeds; that is progress and needs
// fairness, which no model states yet. The witness
// reachExpiryRefreshThenRequestTest shows that path is reachable.
module pinning {
  const FIXES: Set[str]

  pure val G = 4
  pure val GENS = 0.to(G - 1)
  pure val NONE = -1

  val F614 = FIXES.contains("614")

  var live: int -> bool
  var nextGen: int
  var present: bool
  var gen: int
  var pinned: int
  // ghosts
  var staleSent: bool
  var lastAction: str

  action init = all {
    live' = GENS.mapBy(k => k == 0),
    nextGen' = 1,
    present' = true,
    gen' = 0,
    pinned' = NONE,
    staleSent' = false,
    lastAction' = "init",
  }

  // The store can yield a working token now (live, or refreshable: the
  // refresh token is assumed valid; rotation is the other model).
  val usable = present

  // The agent is (re)built: main.fnl/interactive.fnl resolve creds and pin
  // them. Construction calls get-fresh-creds!, so the pinned token is live.
  action build = all {
    present, live.get(gen),
    pinned' = gen,
    live' = live, nextGen' = nextGen, present' = present, gen' = gen,
    staleSent' = staleSent, lastAction' = "build",
  }

  // get-fresh-creds! with an expiring stored token: refresh and persist.
  action refresh = all {
    present, not(live.get(gen)), nextGen < G,
    live' = live.set(nextGen, true), nextGen' = nextGen + 1, gen' = nextGen,
    present' = present, pinned' = pinned, staleSent' = staleSent,
    lastAction' = "refresh",
  }

  // The token a provider request carries.
  val reqToken = if (F614) gen else pinned

  // A provider request (complete / list-models).
  action request = all {
    val tok = reqToken
    all {
      if (F614) present else pinned != NONE,
      not(F614) or live.get(tok),
      staleSent' = (staleSent or (not(live.get(tok)) and usable)),
      live' = live, nextGen' = nextGen, present' = present, gen' = gen, pinned' = pinned,
      lastAction' = if (live.get(tok)) "requestOk" else "request401",
    }
  }

  // Time passes: every access token expires.
  action tick = all {
    live' = GENS.mapBy(_ => false),
    nextGen' = nextGen, present' = present, gen' = gen, pinned' = pinned,
    staleSent' = staleSent, lastAction' = "tick",
  }

  action logout = all {
    present,
    present' = false,
    live' = live, nextGen' = nextGen, gen' = gen, pinned' = pinned,
    staleSent' = staleSent, lastAction' = "logout",
  }

  action login = all {
    nextGen < G,
    live' = live.set(nextGen, true), nextGen' = nextGen + 1, gen' = nextGen, present' = true,
    pinned' = pinned, staleSent' = staleSent, lastAction' = "login",
  }

  action step = any { build, refresh, request, tick, logout, login }

  // ---- properties ----

  // Safety: no provider request carries an expired access token while the
  // store has a usable credential.
  val noExpiredTokenRequest = not(staleSent)

  // Whenever auth.json holds a live token, the token a request would carry
  // is live, so the request is not blocked or refused. Together with
  // noExpiredTokenRequest this is the safety half of "expiry is refreshed and
  // the request proceeds"; the other half (a refresh eventually happens) is
  // progress and is not claimed.
  val requestReadyWhenStoreLive =
    (present and live.get(gen) and reqToken != NONE) implies live.get(reqToken)

  val typeOk = and {
    live.in(GENS.setOfMaps(Set(true, false))),
    nextGen.in(1.to(G)),
    present.in(Set(true, false)),
    gen.in(GENS),
    pinned.in(Set(NONE).union(GENS)),
    staleSent.in(Set(true, false)),
    lastAction.in(Set("init", "build", "refresh", "requestOk", "request401", "tick",
                      "logout", "login")),
  }

  val pinningInductive = and { typeOk, noExpiredTokenRequest, requestReadyWhenStoreLive }
}

// Since #605 today's code carries the fixes, so `current` matches `fixed`.
module current { import pinning(FIXES = Set("614")).* }
module fixed { import pinning(FIXES = Set("614")).* }
