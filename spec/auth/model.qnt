// Model of fen's Codex OAuth credentials and account quota across two fen
// processes (e.g. the TUI and a subagent child, or two terminals) that share
// one auth.json and one codex-usage.json.
//
// Before #605 (the bugs #611-#616):
//   openai_codex_oauth.get-fresh-creds!
//                   -> read auth.json; if the access token is expiring,
//                      POST refresh_token (yields while in flight), then
//                      storage.set (load -> modify -> save). No lock, no
//                      re-read after the POST, no check that the record is
//                      still the one refreshed.
//   openai_codex_keychain.save
//                   -> write tmp sibling (created with the process umask),
//                      chmod 600 tmp, rename over auth.json (atomic, #604)
//   main.fnl / interactive.fnl
//                   -> the provider config resolves creds once (startup or
//                      agent rebuild) and pins them in provider-options.creds;
//                      openai_codex_responses.resolve-creds prefers the pinned
//                      creds over get-fresh-creds!, and a 401 is terminal
//   openai_codex_login.logout!
//                   -> load, drop the record, save (local only; no lock)
//   usage.fnl       -> claim-attempt under fcntl + process mutex; the GET
//                      runs outside the lock and its result replaces windows
//                      and is saved without the lock; record-limit (a 429)
//                      marks windows exhausted under the lock
//
// Since #605 the code carries all six fixes below, so `current` (today's
// code) imports the same FIXES as `fixed`: the refresh runs under
// keychain.with-auth-lock (fen.util.durable_store: process mutex + lfs.lock
// on auth.json.lock), re-reads inside the lock and after a failed POST,
// writes back with keychain.compare-and-set!, shields the POST from cancel;
// resolve-creds calls get-fresh-creds! per request; save creates the tmp
// 0600; usage.M.refresh applies the GET under the cache lock and keeps
// limits stamped `limited-at` >= the GET's send time.
//
// The OAuth server rotates refresh tokens: using generation k issues k' and
// invalidates k. Reusing an invalidated token fails (invalid_grant).
// FIXES names the candidate fixes (by issue number) so the same invariants can
// be checked with each fix on its own and with all of them:
//   611  refresh under a cross-process auth lock, re-read the record inside
//        the lock, and re-read it after a failed POST
//   612  the write-back is conditional on the record still being the one
//        refreshed (compare-and-rename); login/logout take the auth lock
//   613  the refresh POST is shielded from cooperative cancellation
//   614  provider requests resolve credentials per request (no pinning)
//   615  the tmp file is created 0600
//   616  a GET result does not overwrite a 429 recorded while it was in flight
module auth {
  const FIXES: Set[str]

  val F611 = FIXES.contains("611")
  val F612 = FIXES.contains("612")
  val F613 = FIXES.contains("613")
  val F614 = FIXES.contains("614")
  val F615 = FIXES.contains("615")
  val F616 = FIXES.contains("616")

  pure val PROCS = Set(1, 2)
  pure val NONE = -1

  // phase: idle | posting (POST sent, server not yet processed)
  //        | committed (new tokens in memory, not yet written)
  //        | tmp (tmp file written, not yet chmod+renamed)
  type Proc = { phase: str, used: int, got: int, wantPin: bool, pinned: int }
  // valid: refresh tokens the server accepts; live: unexpired access tokens.
  // Access token k and refresh token k are issued together.
  type Srv = { valid: Set[int], live: Set[int], next: int }
  type Store = { present: bool, gen: int }
  type Quota = {
    server: bool,         // account exhausted upstream
    shown: str,           // none | avail | exhausted  (what M.status renders)
    fresh: bool,          // snapshot status :fresh
    get: str,             // none | avail | exhausted  (usage GET in flight + its sample)
    obsSinceGet: bool,    // a 429 was recorded after the in-flight GET was sent
    resetSinceGet: bool,  // reset-at passed after the in-flight GET was sent
    obsNewer: bool,       // ghost: the shown value predates a recorded 429
  }
  // rejectedUsable: a refresh failed (invalid_grant) while the store held a
  //   valid credential. staleRequest: a provider request carried an expired
  //   access token while a valid credential was obtainable. lost: refresh
  //   generations whose rotation was lost to something no client can prevent
  //   (transport loss or a crash after the server committed); it excuses
  //   storeRefreshable only while the store still holds that generation, and
  //   login (recovery) clears it.
  type Ghost = { loggedOut: bool, rejectedUsable: bool, staleRequest: bool, lost: Set[int] }

  var srv: Srv
  var store: Store
  var leakedTmp: bool          // a crashed writer left a token-bearing tmp file behind
  var authLock: int            // fix 611 only: cross-process auth lock holder (0 free)
  var procs: int -> Proc
  var cacheHolder: int -> bool // codex-usage.json.lock (fcntl + process mutex)
  var q: Quota
  var g: Ghost
  var lastAction: str

  pure val idleProc = { phase: "idle", used: NONE, got: NONE, wantPin: false, pinned: NONE }

  action init = all {
    srv' = { valid: Set(0), live: Set(0), next: 1 },
    store' = { present: true, gen: 0 },
    leakedTmp' = false,
    authLock' = 0,
    procs' = PROCS.mapBy(_ => idleProc),
    cacheHolder' = PROCS.mapBy(_ => false),
    q' = { server: false, shown: "none", fresh: false, get: "none",
           obsSinceGet: false, resetSinceGet: false, obsNewer: false },
    g' = { loggedOut: false, rejectedUsable: false, staleRequest: false, lost: Set() },
    lastAction' = "init",
  }

  // A valid credential is obtainable from the store right now.
  val usable = store.present and (srv.live.contains(store.gen) or srv.valid.contains(store.gen))

  action keepQ = q' = q
  action keepRest = all { cacheHolder' = cacheHolder, leakedTmp' = leakedTmp }

  // ---- credentials ----

  // get-fresh-creds! entry: startup/agent rebuild (pin = true) or the usage
  // refresh / per-request resolve (pin = false). Missing record: user error.
  action begin(p: int, pin: bool): bool = all {
    procs.get(p).phase == "idle", store.present,
    val pr = procs.get(p)
    if (srv.live.contains(store.gen))
      all {
        procs' = procs.set(p, { ...pr, pinned: if (pin) store.gen else pr.pinned }),
        srv' = srv, store' = store, authLock' = authLock, g' = g,
      }
    else all {
      // fix 611: the check above and this read happen inside the lock
      not(F611) or authLock == 0,
      authLock' = if (F611) p else authLock,
      procs' = procs.set(p, { ...pr, phase: "posting", used: store.gen, wantPin: pin }),
      srv' = srv, store' = store, g' = g,
    },
    keepQ, keepRest,
    lastAction' = if (pin) "beginPin" else "begin",
  }

  // The token endpoint processes the POST and the response arrives.
  action respond(p: int): bool = all {
    val pr = procs.get(p)
    all {
      pr.phase == "posting",
      if (srv.valid.contains(pr.used))
        all {
          srv' = { valid: srv.valid.exclude(Set(pr.used)).union(Set(srv.next)),
                   live: srv.live.union(Set(srv.next)), next: srv.next + 1 },
          procs' = procs.set(p, { ...pr, phase: "committed", got: srv.next }),
          authLock' = authLock, g' = g,
          lastAction' = "refreshOk",
        }
      else
        // invalid_grant: get-fresh-creds! raises; the caller fails. Fix 611
        // re-reads the store after a failed POST and uses a valid record
        // another process wrote (pi-mono's refreshOAuthTokenWithLock).
        all {
          srv' = srv,
          procs' = procs.set(p, { ...pr, phase: "idle" }),
          authLock' = if (F611) 0 else authLock,
          g' = { ...g, rejectedUsable: g.rejectedUsable or (usable and not(F611)) },
          lastAction' = "refreshRejected",
        },
      store' = store, keepQ, keepRest,
    }
  }

  // Ctrl-C / deadline at the http yield. Before the server processed the POST
  // nothing is lost; after it did, the rotation is committed server-side and
  // the new tokens are dropped. Fix 613 shields the POST from cancellation.
  action cancel(p: int, afterCommit: bool): bool = all {
    val pr = procs.get(p)
    all {
      pr.phase == "posting",
      not(afterCommit and F613),
      srv' = if (afterCommit and srv.valid.contains(pr.used))
               { ...srv, valid: srv.valid.exclude(Set(pr.used)).union(Set(srv.next)),
                         live: srv.live.union(Set(srv.next)), next: srv.next + 1 }
             else srv,
      procs' = procs.set(p, { ...pr, phase: "idle" }),
      authLock' = if (F611) 0 else authLock,
      store' = store, g' = g, keepQ, keepRest,
      lastAction' = if (afterCommit) "cancelAfterCommit" else "cancelBeforeCommit",
    }
  }

  // Transport loss after the server committed (timeout, dropped connection):
  // no client design can recover the tokens; recorded as inherent.
  action responseLost(p: int): bool = all {
    val pr = procs.get(p)
    all {
      pr.phase == "posting", srv.valid.contains(pr.used),
      srv' = { valid: srv.valid.exclude(Set(pr.used)).union(Set(srv.next)),
               live: srv.live.union(Set(srv.next)), next: srv.next + 1 },
      procs' = procs.set(p, { ...pr, phase: "idle" }),
      authLock' = if (F611) 0 else authLock,
      g' = { ...g, lost: g.lost.union(Set(pr.used)) },
      store' = store, keepQ, keepRest,
      lastAction' = "responseLost",
    }
  }

  // keychain.save step 1: the tmp file is written. Today it is created with
  // the umask (0644 typically) and only chmodded just before the rename.
  action writeTmp(p: int): bool = all {
    procs.get(p).phase == "committed",
    procs' = procs.set(p, { ...procs.get(p), phase: "tmp" }),
    leakedTmp' = leakedTmp,
    srv' = srv, store' = store, authLock' = authLock, g' = g,
    cacheHolder' = cacheHolder, keepQ,
    lastAction' = "writeTmp",
  }

  // keychain.save step 2: chmod 600 tmp, rename over auth.json. storage.set
  // re-loads the file first, so this write ignores whatever happened to the
  // record since the refresh began (logout, login, another refresh).
  // Fix 612 renames only if the stored record still carries the refresh
  // token that was used; otherwise the result is dropped.
  action rename(p: int): bool = all {
    val pr = procs.get(p)
    val writes = not(F612) or (store.present and store.gen == pr.used)
    all {
      pr.phase == "tmp",
      store' = if (writes) { present: true, gen: pr.got } else store,
      procs' = procs.set(p, { ...pr, phase: "idle",
                              pinned: if (pr.wantPin and writes) pr.got else pr.pinned }),
      leakedTmp' = leakedTmp,
      authLock' = if (F611) 0 else authLock,
      g' = g,
      srv' = srv, cacheHolder' = cacheHolder, keepQ,
      lastAction' = "rename",
    }
  }

  // A provider request. Today it carries the pinned access token, and a
  // stale one yields a 401 that is terminal for the turn. Fix 614 resolves
  // creds per request: the request carries the stored token and goes out only
  // while that token is live; an expired one must first be refreshed (begin).
  // This is a safety guard: it rules out sending an expired token, it does
  // not show that the refresh happens (no fairness is modelled).
  action request(p: int): bool = all {
    val pr = procs.get(p)
    val tok = if (F614) store.gen else pr.pinned
    all {
      pr.phase == "idle",
      if (F614) store.present else pr.pinned != NONE,
      not(F614) or srv.live.contains(tok),
      g' = if (srv.live.contains(tok)) g
           else { ...g, staleRequest: g.staleRequest or usable },
      srv' = srv, store' = store, authLock' = authLock, procs' = procs,
      keepQ, keepRest,
      lastAction' = if (srv.live.contains(tok)) "requestOk" else "request401",
    }
  }

  // Process death at any point; the kernel drops its fcntl locks. Dying with
  // committed-but-unwritten tokens loses the rotation (inherent).
  // The process is restarted with nothing pinned. A tmp file stays behind.
  action crash(p: int): bool = all {
    val pr = procs.get(p)
    all {
      procs' = procs.set(p, idleProc),
      authLock' = if (authLock == p) 0 else authLock,
      cacheHolder' = cacheHolder.set(p, false),
      g' = if ((pr.phase == "committed" or pr.phase == "tmp") and srv.valid.contains(pr.got))
             { ...g, lost: g.lost.union(Set(pr.used)) }
           else g,
      // tmp files are created 0600 under fix 615; a leftover one is harmless
      leakedTmp' = (leakedTmp or (pr.phase == "tmp" and not(F615))),
      srv' = srv, store' = store, keepQ,
      lastAction' = "crash",
    }
  }

  // Access tokens expire with time; refresh tokens do not.
  action tick = all {
    srv' = { ...srv, live: Set() },
    store' = store, authLock' = authLock, procs' = procs, g' = g, keepQ, keepRest,
    lastAction' = "tick",
  }

  // fen --logout openai-codex (local only: the server keeps the tokens valid).
  action logout = all {
    store.present,
    not(F612) or authLock == 0,
    store' = { present: false, gen: NONE },
    g' = { ...g, loggedOut: true },
    srv' = srv, authLock' = authLock, procs' = procs, keepQ, keepRest,
    lastAction' = "logout",
  }

  // fen --login openai-codex: a new token family. It is the recovery from a
  // lost rotation, so it clears the inherent-loss excuse.
  action login = all {
    not(F612) or authLock == 0,
    srv' = { valid: srv.valid.union(Set(srv.next)), live: srv.live.union(Set(srv.next)),
             next: srv.next + 1 },
    store' = { present: true, gen: srv.next },
    g' = { ...g, loggedOut: false, lost: Set() },
    authLock' = authLock, procs' = procs, keepQ, keepRest,
    lastAction' = "login",
  }

  // usage.with-cache-lock: process mutex + fcntl write lock on a stable inode.
  action cacheLock(p: int, acquire: bool): bool = all {
    if (acquire) PROCS.forall(o => not(cacheHolder.get(o))) else cacheHolder.get(p),
    cacheHolder' = cacheHolder.set(p, acquire),
    srv' = srv, store' = store, leakedTmp' = leakedTmp, authLock' = authLock,
    procs' = procs, g' = g, keepQ,
    lastAction' = if (acquire) "cacheLock" else "cacheUnlock",
  }

  // ---- quota (usage.fnl) ----

  action keepAuth = all {
    srv' = srv, store' = store, leakedTmp' = leakedTmp, authLock' = authLock,
    procs' = procs, cacheHolder' = cacheHolder, g' = g,
  }

  // claim-attempt succeeded; the GET goes out and samples the server.
  action qSendGet = all {
    q.get == "none",
    q' = { ...q, get: if (q.server) "exhausted" else "avail",
                 obsSinceGet: false, resetSinceGet: false },
    keepAuth, lastAction' = "qSendGet",
  }

  // Other usage exhausts the account upstream.
  action qExhaust = all {
    not(q.server),
    q' = { ...q, server: true },
    keepAuth, lastAction' = "qExhaust",
  }

  // A completion gets usage_limit_reached: record-limit marks the window
  // exhausted (under the cache lock), keeps retrieved-at, clears failure.
  action q429 = all {
    q.server,
    q' = { ...q, shown: "exhausted", obsNewer: false,
                 fresh: q.fresh or q.shown == "none",
                 obsSinceGet: q.get != "none" },
    keepAuth, lastAction' = "q429",
  }

  // The GET returns: today its windows replace state.windows wholesale,
  // retrieved-at = now, and the cache is saved outside the lock.
  // A sampled exhausted window whose reset-at has passed renders as 100%.
  action qReturn = all {
    q.get != "none",
    val sample = if (q.get == "exhausted" and q.resetSinceGet) "avail" else q.get
    val keepObs = F616 and q.obsSinceGet
    q' = { ...q, get: "none",
                 shown: if (keepObs) q.shown else sample,
                 fresh: if (keepObs) q.fresh else true,
                 obsNewer: if (keepObs) q.obsNewer else q.obsSinceGet },
    keepAuth, lastAction' = "qReturn",
  }

  // reset-at passes: the server resets; M.remaining shows 100 and the
  // snapshot turns stale.
  action qReset = all {
    q' = { ...q, server: false,
                 shown: if (q.shown == "exhausted") "avail" else q.shown,
                 fresh: false, obsNewer: false,
                 resetSinceGet: q.get != "none" },
    keepAuth, lastAction' = "qReset",
  }

  // 60 s pass: the snapshot is no longer fresh.
  action qAge = all { q' = { ...q, fresh: false }, keepAuth, lastAction' = "qAge" }

  action step = any {
    nondet p = PROCS.oneOf()
    nondet pin = Set(true, false).oneOf()
    nondet after = Set(true, false).oneOf()
    any {
      begin(p, pin), respond(p), cancel(p, after), responseLost(p),
      writeTmp(p), rename(p), request(p), crash(p), cacheLock(p, pin),
    },
    tick, logout, login,
    qSendGet, qExhaust, q429, qReturn, qReset, qAge,
  }

  // ---- properties ----

  // The store never holds only a revoked refresh token, unless the new one
  // was lost to something no client can prevent (crash or transport loss
  // after the server committed) and the store still holds the generation
  // whose rotation was lost.
  val storeRefreshable =
    g.lost.contains(store.gen) or not(store.present) or srv.valid.contains(store.gen)
      or PROCS.exists(p => (procs.get(p).phase == "committed" or procs.get(p).phase == "tmp")
                           and srv.valid.contains(procs.get(p).got))

  // After logout, nothing writes credentials back until the next login.
  val noResurrection = g.loggedOut implies not(store.present)

  // A refresh is reported failed (invalid_grant) only when the store holds no
  // valid credential.
  val noRefreshRejectedWhileUsable = not(g.rejectedUsable)

  // Safety only: no provider request carries an expired access token while a
  // valid credential is obtainable. It does not say that an expired token is
  // refreshed and the request then goes out (that is progress; see FINDINGS).
  val noExpiredTokenRequest = not(g.staleRequest)

  // At most one refresh per credential is in flight across processes.
  val singleRefreshInFlight =
    PROCS.filter(p => procs.get(p).phase != "idle").size() <= 1

  // Tokens never sit in a file other local users can read: today every
  // tmp file is umask-readable until its chmod, and a crash leaves it so.
  val secretsPrivate =
    not(leakedTmp) and (F615 or PROCS.forall(p => procs.get(p).phase != "tmp"))

  // auth.json only ever holds a whole record the server issued: the store
  // changes only at rename, so a crash at any step leaves the old record.
  val storeWholeRecord = store.present implies (store.gen >= 0 and store.gen < srv.next)

  // The usage cache lock admits one holder and a dead holder frees it.
  val cacheLockExclusive = PROCS.filter(p => cacheHolder.get(p)).size() <= 1

  // Quota is never shown exhausted once the window has reset.
  val quotaNoStaleExhausted = q.shown == "exhausted" implies q.server

  // A fresh "available" never hides a usage_limit_reached recorded after
  // the shown data was sampled.
  val quotaFreshNotContradicted = not(q.fresh and q.shown == "avail" and q.obsNewer)

  val allInvariants = and {
    storeRefreshable, noResurrection, noRefreshRejectedWhileUsable, noExpiredTokenRequest,
    singleRefreshInFlight,
    secretsPrivate, storeWholeRecord, cacheLockExclusive, quotaNoStaleExhausted,
    quotaFreshNotContradicted,
  }
}

module current { import auth(FIXES = Set("611", "612", "613", "614", "615", "616")).* }
module fixed { import auth(FIXES = Set("611", "612", "613", "614", "615", "616")).* }
module fix611 { import auth(FIXES = Set("611")).* }
module fix612 { import auth(FIXES = Set("612")).* }
module fix613 { import auth(FIXES = Set("613")).* }
module fix614 { import auth(FIXES = Set("614")).* }
module fix615 { import auth(FIXES = Set("615")).* }
module fix616 { import auth(FIXES = Set("616")).* }
