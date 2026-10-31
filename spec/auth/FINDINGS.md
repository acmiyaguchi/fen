# Codex credentials and account quota

Model: [`model.qnt`](model.qnt).
Scope: two fen processes (TUI + subagent child, or two terminals) sharing one `auth.json` and one `codex-usage.json`.
The model covers access-token expiry, refresh-token rotation (the server invalidates the old refresh token when it issues a new one, and rejects a reused one), concurrent refresh, cancel or transport loss mid-POST, crash at each step of the tmp-and-rename write, logout and login while a refresh is in flight, pinned provider credentials, the usage cache lock, and quota refresh vs `usage_limit_reached` vs `reset_at`.

Code: `extensions/adapters/providers/openai/{openai_codex_oauth,openai_codex_keychain,openai_codex_login,openai_codex_responses,usage}.fnl`, `packages/fen/src/fen/main.fnl` (auth-backend branch of provider resolution), `packages/fen/src/fen/interactive.fnl` (`make-agent-from-opts`), `packages/util/src/fen/util/file_mutex.fnl`, `packages/core/src/fen/core/extensions/register/auth_backend.fnl`.

All probes below were throwaway Busted files (`zz_probe_auth_*_test.fnl`) run with `make test TESTS=...`, then deleted.
They used temp dirs, a stubbed `fen.util.http`, and a fake OAuth server that rotates `Rk -> R(k+1)` and answers `400 invalid_grant refresh_token_reused` to a reused token.
They made no network calls and touched no real credentials.

## Bugs

### #611: Two processes refresh concurrently; the loser fails even though valid credentials are on disk

Counterexample (`noSpuriousAuthFailure`, `singleRefreshInFlight`): `tick → begin(1) → begin(2) → respond(1) → writeTmp(1) → rename(1) → respond(2)` (the shortest trace the simulator finds for `noSpuriousAuthFailure` is #614's; `singleRefreshInFlight` is violated as soon as both processes are posting).
`get-fresh-creds!` reads `auth.json`, sees the access token expiring, and POSTs the refresh token.
It takes no lock and does not re-read after a failed POST.
A second process that read the store before the first one wrote back POSTs the same refresh token.
The server has already rotated it, so the second process errors out with `refresh HTTP 400` while `auth.json` already holds the valid `R1`.
In practice: parallel subagent children spawned while the token is near expiry, or the TUI's usage refresh racing a child's startup.
The provider at startup (`main.fnl:236`) turns this into "defaultProvider openai-codex is unavailable".
If the server treats reuse as theft and revokes the whole token family (the OAuth security BCP recommends this), both processes lose their tokens and the user has to log in again (see Open questions).

Confirmed: two coroutines run `get-fresh-creds!` against one temp `auth.json`, each yielding inside the stubbed POST:

```
A1 A:	true	R1
A1 B:	false	...openai_codex_oauth.fnl:86: auth.openai_codex: refresh HTTP 400: {"error":"invalid_grant","error_description":"refresh_token_reused"}
A1 store refresh:	R1	server valid R1:	true
```

### #612: A refresh in flight writes credentials back after logout (and clobbers a concurrent login)

Counterexample (`noResurrection`): `tick → begin → logout → refreshOk → writeTmp → rename`.
`storage.set` is load → modify → save with no lock and no check that the record is still the one that was refreshed.
`logout!` is the same load → delete → save.
A refresh that started before the logout re-creates the `openai-codex` record when it finishes.
By the same mechanism, a refresh of the old account finishing after `fen --login` overwrites the new login.

Confirmed: coroutine A suspends inside the refresh POST, `login.logout!` runs on the same path, then A resumes:

```
A2 logout: openai-codex credentials removed from /tmp/tmp.tst3SxPfFn/auth.json.
A2 after logout record:	nil
A2 after refresh completes record:	R1
```

### #613: Cancelling during the refresh POST loses the rotation and forces a re-login

Counterexample (`storeRefreshable`): `tick → beginPin → cancelAfterCommit`.
`refresh!` passes the caller's cooperative yield into `http.request`, and the usage refresh deliberately re-raises cancellation.
A cancel that lands after the server has processed the POST, but before the response is consumed, drops the new tokens.
`auth.json` keeps `R0`, which the server has already invalidated, so every later refresh fails until the user logs in again.
The model separates this controllable loss from transport loss and crashes after commit, which no client can prevent.
Those set the `inherentLoss` ghost, and `storeRefreshable` excuses them.

Confirmed: the fake server commits `R0 → R1` and then yields; the probe resumes the coroutine with a cancel:

```
A3 cancel:	false	...zz_probe_auth_refresh_test.fnl:106: cancelled
A3 store refresh:	R0	server valid R0:	nil	R1:	true
A3 next refresh:	false	...openai_codex_oauth.fnl:86: auth.openai_codex: refresh HTTP 400: {"error":"invalid_grant","error_description":"refresh_token_reused"}
```

### #614: Provider requests use credentials pinned at agent construction; expiry mid-session is a terminal 401

Counterexample (`noSpuriousAuthFailure`): `beginPin → tick → request401`.
`main.fnl` resolves auth-backend credentials when the provider config is built and returns them as `:creds`.
`interactive.make-agent-from-opts` copies them into `provider-options.creds` (`interactive.fnl:74`).
`openai_codex_responses.resolve-creds` prefers `opts.creds` over `get-fresh-creds!`.
So `complete` and `list-models` send the startup access token for the agent's whole life, which ends only at `/model`, `/new`, `/thinking`, and other rebuilds.
A 401 maps to `:authentication-failed` and nothing re-resolves.
`REFRESH-MARGIN-MS` (60 s) is sized for "a single in-flight request", but with pinning it has to cover the whole session.
The `resolve-creds` docstring ("so /reload picks up rotated tokens") describes the fallback path, which the pinned path skips.

Confirmed: `list-models` called with `{:creds {:access "OLD" :expires 0}}`, a stub `get-fresh-creds!` that would return `NEW`, and a stub HTTP returning 401:

```
A4 sent:	Bearer OLD	fresh-calls:	0	ok:	false	reason:	authentication-failed
```

Line trace for the wiring: `main.fnl:236-251` (`:creds creds`) → `interactive.fnl:74` → `openai_codex_responses.fnl:191,278`.

### #615: Token-bearing tmp files are created world-readable until the chmod; a crash leaves one behind

Counterexample (`secretsPrivate`): `tick → beginPin → refreshOk → writeTmp` (and `crash` in that state leaks the file).
`keychain.save` opens `auth.json.<rand>` with `io.open` (umask perms), writes the tokens, and only then runs `chmod 600` and renames.
`ensure-dir!` also creates the auth dir with default perms.
Under the usual umask 022, other local users can read the tokens during that window, and a crash or kill between write and chmod leaves a readable tmp file next to `auth.json` indefinitely.
The final `auth.json` is 0600.

Confirmed: the probe wraps `os.execute` to stat the tmp file at the moment `chmod 600` is invoked on it:

```
A5 tmp perms before chmod:	/tmp/tmp.CxkZwmnimS/auth.json.lua_d5xvSg rw-r--r--
A5 final perms:	rw-------
```

### #616: A usage GET in flight overwrites a `usage_limit_reached` recorded meanwhile and reports it as fresh

Counterexample (`quotaFreshNotContradicted`): `qSendGet → qExhaust → q429 → qReturn`.
`M.refresh` claims the attempt under the cache lock, but runs the GET and applies its result outside the lock.
When the result arrives it replaces `state.windows` wholesale, sets `retrieved-at = now`, and `save-cache`s without the lock.
A 429 that `record-limit` recorded while the GET was in flight (same process, or another process via the disk cache) is erased.
The status bar then shows pre-exhaustion data marked `fresh`.
Low severity: the error lasts at most one 60 s freshness window per 429, because the next codex request 429s again and re-records the exhaustion.

Confirmed: a `M.refresh` coroutine suspends inside the stubbed GET (server data: 97% used), `record-limit` runs, then the GET completes:

```
Q1 after 429:	0	fresh
Q1 after GET returns:	3.0	fresh
Q1 disk:	3.0
```

## Holds

- `storeWholeRecord`: the store changes only at `rename`, so a crash at any step leaves the previous whole record (the #604 tmp+rename fix).
  The model can't show a torn `auth.json`; the remaining crash residue is the #615 tmp file.
- `cacheLockExclusive`: `with-cache-lock` combines the process-local FIFO mutex (coroutines in one process) with an `lfs.lock` fcntl write lock on a stable, never-renamed inode (across processes).
  The kernel drops the fcntl lock when the holder dies, so a dead holder never strands the cross-process lock.
- `quotaNoStaleExhausted`: `M.remaining` shows 100% once `now >= reset-at` and `M.snapshot` marks such a snapshot stale, so quota is never shown exhausted after its reset.
  This holds even when a GET sampled before the reset returns after it.
- No lost rotation from concurrent refreshes alone: under single-use rotation the loser's POST fails and writes nothing, so `storeRefreshable` is broken only by #613 (and by inherent post-commit loss).
  #611 is a spurious failure, not a lost token, unless the server revokes the whole family on reuse.

## Candidate fix (modelled as `fixed`)

- Refresh under a cross-process auth lock: fcntl on a stable `auth.json.lock` inode plus the existing `file_mutex` for coroutines, i.e. the usage cache's `with-cache-lock` pattern.
  Re-read the record inside the lock and return it untouched if it is no longer expiring.
  This fixes #611 and makes `singleRefreshInFlight` hold.
  pi-mono's `auth-storage.ts` `refreshOAuthTokenWithLock` does exactly this, and on failure also re-reads the file in case another instance succeeded.
- `logout!` and `login!` take the same lock, so a stale refresh can't write back afterwards (#612).
  Without a lock, compare-and-swap on the refresh token (write only if the stored record still carries the token that was used) would also do.
- Shield the refresh POST from cooperative cancellation: let it complete and persist, then honour the cancel (#613).
  Timeouts and connection loss after commit stay inherent.
- Resolve credentials per request instead of pinning them, or on a 401 call `get-fresh-creds!` once and retry (#614).
- Create the tmp file 0600 (e.g. `umask 077` around the open, or open via a helper that sets the mode) and create the auth dir 0700 (#615).
- In `M.refresh`, apply the GET result under the cache lock and keep windows whose `usage_limit_reached` observation is newer than the GET's send time (#616).

`fixed.allInvariants` holds (20 000 samples × 20 steps).
Witness runs confirm the fixed variant still reaches renames, rotations, and 429s that land during a GET, so the result is not vacuous.

## Open questions

- **Server reuse policy.** Whether `auth.openai.com` revokes the whole token family when it sees a reused refresh token, or allows a reuse grace window, was not checked (no network).
  With family revocation, #611 escalates from a spurious failure to a forced re-login for every process.
  With a grace window, #611 and #613 mostly disappear.
- **Logout is local only.** `logout!` deletes the file record but does not revoke anything server-side.
  Running processes keep using their pinned access token (#614) until it expires.
  That may be the intended meaning of "logout", but it isn't documented.
- **`file_mutex` with a main-thread owner.** `current-owner` returns nil outside a coroutine, so a synchronous `with-file` records `owner = nil` and the lock looks free.
  This is harmless only because a synchronous body cannot yield.
  A synchronous body that resumes another coroutine taking the same key would let both in.
  No such call path was found.
- **Abandoned coroutine holders.** `file_mutex` state survives `/reload` and "holders must be resumed to unwind".
  A holder that is never resumed again (e.g. `usage_state.refresh-co` after the extension is disabled) keeps the process-local mutex and the fcntl fd forever.
  Re-enabling resumes it, so no stranding was demonstrated.

## Core

The essential contract is small: *one credential record, one writer at a time; a refresh is read-check-POST-write inside that critical section, and the write is conditional on the record still being the one refreshed*.
Rotation makes the refresh token a linear resource: it can be spent once, so "who may spend it" has to be serialized across processes, and the result has to be persisted before anyone can interrupt.
Today fen has the pieces (atomic rename, an fcntl lock helper, a coroutine mutex) but uses the lock only for the quota cache, and pins access tokens so refresh rarely runs where it matters.
A single `with-auth-lock` around refresh, login, and logout, plus per-request resolution, would remove #611, #612, #613, #614 and make most of the remaining behaviour straight-line code.
