# Codex credentials and account quota

Model: [`model.qnt`](model.qnt).
Scope: two fen processes (TUI + subagent child, or two terminals) sharing one `auth.json` and one `codex-usage.json`.
The model covers access-token expiry, refresh-token rotation (the server invalidates the old refresh token when it issues a new one, and rejects a reused one), concurrent refresh, cancel or transport loss mid-POST, crash at each step of the tmp-and-rename write, logout and login while a refresh is in flight, pinned provider credentials, the usage cache lock, and quota refresh vs `usage_limit_reached` vs `reset_at`.

Code: `extensions/adapters/providers/openai/{openai_codex_oauth,openai_codex_keychain,openai_codex_login,openai_codex_responses,usage}.fnl`, `packages/fen/src/fen/main.fnl` (auth-backend branch of provider resolution), `packages/fen/src/fen/interactive.fnl` (`make-agent-from-opts`), `packages/util/src/fen/util/file_mutex.fnl`, `packages/core/src/fen/core/extensions/register/auth_backend.fnl`.

Proof models for the individual contracts live in [`proofs/`](#proof-models): [`rotation`](proofs/rotation/model.qnt), [`pinning`](proofs/pinning/model.qnt), and [`quota`](proofs/quota/model.qnt).

The bugs were first confirmed with throwaway Busted files; those probes are now kept as `known-bug` tests in `extensions/adapters/providers/openai/tests/issue_<n>_*_test.fnl` (listed per bug below).
They pass while the bug reproduces and fail once it stops.
They use temp dirs, a stubbed `fen.util.http`, and a fake OAuth server that rotates `Rk -> R(k+1)` and answers `400 invalid_grant refresh_token_reused` to a reused token.
They make no network calls and touch no real credentials.

Evidence kinds follow [`../README.md`](../README.md#kinds-of-evidence).

## Input assumptions

What the environment actions of the integration model can and cannot produce:

- **Two processes, one file each.** `PROCS = {1, 2}` share one `auth.json` and one `codex-usage.json`. A third process adds no new interleaving for these contracts (every race here is pairwise).
- **Server.** Refresh tokens rotate single-use: using a valid `k` invalidates it and issues `k'`, and a reused token is rejected. Access token `k` and refresh token `k` are issued together. The model does **not** produce family revocation on reuse or a reuse grace window (see Open questions), server-side revocation at logout, or a rejected *valid* token (outages are a transport failure, not modelled).
- **Clock.** `tick` expires every access token at once; refresh tokens never expire. There is no per-token expiry order and no clock skew. A request is atomic: a token cannot expire between the liveness check and the server reading it (the real `REFRESH-MARGIN-MS` of 60 s is assumed to cover that).
- **Cancel and failure.** A cancel lands only at the HTTP yield of the refresh POST, either before or after the server processed it. Transport loss is modelled only after commit (before commit it is the same as a cancel before commit). A crash can happen in any phase and frees the kernel locks.
- **Login and logout** are atomic local file operations; login starts a new token family, logout only deletes the local record.
- **Quota.** One account, one window. A GET samples the upstream value when sent; a 429 can be recorded only while the account is exhausted; `qReset` models `reset_at` passing. Malformed or partial usage payloads are not produced.
- **Not modelled.** Torn writes inside a single `write` call (the tmp+rename makes them unobservable), `file_mutex` internals (see Open questions), more than one provider, and the PKCE login exchange.

Ghosts: `rejectedUsable`, `staleRequest`, `loggedOut`, `obsNewer`, and `lost`, a set of refresh generations whose rotation was lost to something no client can prevent.
`lost` excuses `storeRefreshable` only while the store still holds that generation, and login (the recovery) clears it.
It used to be a single sticky `inherentLoss` flag that excused every later state, so a later #613 after a recovered transport loss went unnoticed; `w613NotExcusedAfterRecoveryTest` is the check that fails with the old flag.

## Bugs

### #611: Two processes refresh concurrently; the loser fails even though valid credentials are on disk

Counterexample (`noRefreshRejectedWhileUsable`, `singleRefreshInFlight`): `tick → begin(1) → begin(2) → respond(1) → writeTmp(1) → rename(1) → respond(2)`; `singleRefreshInFlight` is violated as soon as both processes are posting.
The old row checked `noSpuriousAuthFailure`, which merged this rejection with #614's stale request, and the simulator usually found #614's shorter trace for it.
The two are now separate invariants, and the witness pins the trace to #611: the failure is the refresh rejection itself, the store holds the winner's valid `R1`, and no stale request or inherent loss is involved.

Evidence: counterexample (`w611ConcurrentRefreshLoserFailsTest`, integration and [rotation](proofs/rotation/witnesses.qnt) models), confirmed (`issue_611_concurrent_refresh_loser_fails_test.fnl`).
`get-fresh-creds!` reads `auth.json`, sees the access token expiring, and POSTs the refresh token.
It takes no lock and does not re-read after a failed POST.
A second process that read the store before the first one wrote back POSTs the same refresh token.
The server has already rotated it, so the second process errors out with `refresh HTTP 400` while `auth.json` already holds the valid `R1`.
In practice: parallel subagent children spawned while the token is near expiry, or the TUI's usage refresh racing a child's startup.
The provider at startup (`main.fnl:236`) turns this into "defaultProvider openai-codex is unavailable".
If the server treats reuse as theft and revokes the whole token family (the OAuth security BCP recommends this), both processes lose their tokens and the user has to log in again (see Open questions).

Confirmed: two coroutines run `get-fresh-creds!` against one temp `auth.json`, each yielding inside the stubbed POST (original throwaway probe output; the kept probe asserts the same):

```
A1 A:	true	R1
A1 B:	false	...openai_codex_oauth.fnl:86: auth.openai_codex: refresh HTTP 400: {"error":"invalid_grant","error_description":"refresh_token_reused"}
A1 store refresh:	R1	server valid R1:	true
```

### #612: A refresh in flight writes credentials back after logout (and clobbers a concurrent login)

Counterexample (`noResurrection`): `tick → begin → logout → refreshOk → writeTmp → rename`.

Evidence: counterexample (`w612RefreshResurrectsAfterLogoutTest`, integration and rotation models), confirmed (`issue_612_refresh_resurrects_after_logout_test.fnl`; the login-clobber variant is a line trace through the same `storage.set`).
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
Those add the lost generation to the `lost` ghost, and `storeRefreshable` excuses them only while the store still holds that generation (see Input assumptions).

Evidence: counterexample (`w613CancelAfterCommitLosesRotationTest`, and `w613NotExcusedAfterRecoveryTest` for the same bug after a recovered transport loss), confirmed (`issue_613_cancel_after_commit_loses_rotation_test.fnl`: the stubbed transport commits on the fake server, then calls the caller's cooperative yield, which raises the cancel).

Confirmed: the fake server commits `R0 → R1` and then yields; the probe resumes the coroutine with a cancel:

```
A3 cancel:	false	...zz_probe_auth_refresh_test.fnl:106: cancelled
A3 store refresh:	R0	server valid R0:	nil	R1:	true
A3 next refresh:	false	...openai_codex_oauth.fnl:86: auth.openai_codex: refresh HTTP 400: {"error":"invalid_grant","error_description":"refresh_token_reused"}
```

### #614: Provider requests use credentials pinned at agent construction; expiry mid-session is a terminal 401

Counterexample (`noExpiredTokenRequest`): `beginPin → tick → request401`.

Evidence: counterexample (`w614PinnedTokenExpires401Test`, integration and [pinning](proofs/pinning/witnesses.qnt) models), confirmed (`issue_614_pinned_creds_expire_401_test.fnl` for `list-models`; the `main.fnl` → `interactive.fnl` wiring is a line trace).
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

Evidence: counterexample (`w615TmpWorldReadableTest`), confirmed (`issue_615_tmp_auth_file_umask_readable_test.fnl`).
The kept probe is umask-independent: at the moment `chmod 600 <tmp>` runs, the tmp already holds the refresh token and has the same mode as a control file created by `io.open` (that is, whatever the umask gives; `rw-r--r--` under 022).
A kill between write and chmod is approximated by making that `chmod` raise; the token-bearing tmp file stays next to `auth.json`.
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

Evidence: counterexample (`w616GetOverwrites429Test`, integration and [quota](proofs/quota/witnesses.qnt) models), confirmed (`issue_616_usage_get_overwrites_limit_test.fnl`).
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

Evidence: sampled (integration model rows), plus the inductive obligations listed under Proof models where noted.

- `storeWholeRecord`: the store changes only at `rename`, so a crash at any step leaves the previous whole record (the #604 tmp+rename fix).
  The model can't show a torn `auth.json`; the remaining crash residue is the #615 tmp file.
- `cacheLockExclusive`: `with-cache-lock` combines the process-local FIFO mutex (coroutines in one process) with an `lfs.lock` fcntl write lock on a stable, never-renamed inode (across processes).
  The kernel drops the fcntl lock when the holder dies, so a dead holder never strands the cross-process lock.
- `quotaNoStaleExhausted`: `M.remaining` shows 100% once `now >= reset-at` and `M.snapshot` marks such a snapshot stale, so quota is never shown exhausted after its reset.
  This holds even when a GET sampled before the reset returns after it.
  Inductive in the quota proof model, today's design included.
- No lost rotation from concurrent refreshes alone: under single-use rotation the loser's POST fails and writes nothing, so `storeRefreshable` is broken only by #613 (and by inherent post-commit loss).
  #611 is a spurious failure, not a lost token, unless the server revokes the whole family on reuse.

## Candidate fixes (named: `FIXES`)

Each fix is guarded by `FIXES.contains("<issue>")`; `fixed` enables all six and `fix<issue>` enables one.

- **611.** Refresh under a cross-process auth lock: fcntl on a stable `auth.json.lock` inode plus the existing `file_mutex` for coroutines, i.e. the usage cache's `with-cache-lock` pattern.
  Re-read the record inside the lock and return it untouched if it is no longer expiring.
  On a failed POST, re-read the file and use a valid record another process wrote.
  pi-mono's `auth-storage.ts` `refreshOAuthTokenWithLock` does all three.
  The lock gives `singleRefreshInFlight`; the re-read after failure is what gives `noRefreshRejectedWhileUsable`.
  The lock alone is not enough: a refresh of a generation lost to a transport failure, overtaken by a login, is still rejected while the new login is valid (the rotation mutant `no re-read of auth.json after a failed POST` finds it).
- **612.** The write-back is a compare-and-rename: rename only if the stored record still carries the refresh token that was used, otherwise drop the result. `logout!` and `login!` also wait for the auth lock when one is held.
  The compare-and-rename alone makes `noResurrection` hold (`fix612`), without the lock.
- **613.** Shield the refresh POST from cooperative cancellation: let it complete and persist, then honour the cancel.
  Timeouts and connection loss after commit stay inherent.
- **614.** Resolve credentials per request instead of pinning them (modelled), or on a 401 call `get-fresh-creds!` once and retry (not modelled).
- **615.** Create the tmp file 0600 (e.g. `umask 077` around the open, or open via a helper that sets the mode) and create the auth dir 0700.
- **616.** In `M.refresh`, apply the GET result under the cache lock and keep windows whose `usage_limit_reached` observation is newer than the GET's send time.

`fixed.allInvariants` and each `fix<issue>` row hold (sampled: 20 000 samples × 20 steps).
Reachability witnesses (`reach...Test` in [`witnesses.qnt`](witnesses.qnt)) show the fixed design still completes and persists refreshes, makes the second process wait for the lock and then use the new token, cancels before commit, logs out after a refresh, drops a stale rename (fix 612 alone), recovers from an inherent loss by login, refreshes an expired token and then sends the request, and keeps a 429 that lands during a GET.
Mutants (`mutants.tsv`) remove each fix's guard in turn; the named invariant catches every one.

### Safety, not progress, for #614

With fix 614 a request carrying an expired token is not *sent*: the request step requires the stored token to be live.
`noExpiredTokenRequest` (formerly part of `noSpuriousAuthFailure`) is therefore a safety property: no request goes out with an expired token while a valid credential is obtainable.
It does not show that expiry *triggers* a refresh and that the request then proceeds; a design that never sends anything would satisfy it too.
That progress property needs fairness assumptions (the refresh is eventually scheduled), which no model states yet, so it is not claimed (README: no liveness).
What is shown instead: the path is reachable (`reachExpiryRefreshThenRequestTest`, both models), and the pinning proof model adds the safety half of progress, `requestReadyWhenStoreLive`: whenever `auth.json` holds a live token, the token a request would carry is live, so the request is not blocked.
A pinned design that merely refuses expired tokens fails that invariant (pinning mutant 1).

## Proof models

Small models of the individual contracts, beside the integration model, each with `checks.tsv`, `witnesses.qnt`, `mutants.tsv`, and `verify.tsv`.
They use scalar variables and maps over the constant domains `PROCS = {1, 2}` and `GENS = 0..3`; issuing a token is disabled once `GENS` is used up, which bounds the number of rotations and logins (4 generations), not the depth.
Each has `current` (today) and `fixed` instances, so today's bug shows as a counterexample there too.

| Model | Contract | State |
| --- | --- | --- |
| [`rotation`](proofs/rotation/model.qnt) | OAuth refresh rotation, logout, login, cancel; two clients (#611, #612, #613) | server `valid[k]`, issued counter, store (present, generation), per-client phase `idle → posting → srv (server committed) → got (response consumed) → idle (persisted)`, used/got generation, auth-lock holder, ghosts |
| [`pinning`](proofs/pinning/model.qnt) | pinned credentials vs per-request resolution (#614) | `live[k]`, store generation, pinned token, ghost |
| [`quota`](proofs/quota/model.qnt) | GET snapshot vs a later 429 (#616) | seven booleans/enums, all finite |

The rotation model's `fixed` instance is proved with an inductive strengthening: the lock is held exactly by the client between POST and persist (`lockOwnsInflight`); nothing at or above the issue counter is valid; the store and clients refer only to issued tokens; and a client past the server commit holds a valid successor that is not yet in the store.

Verify results (`SPEC_VERIFY_JOBS=1 JVM_ARGS=-Xmx3g`, one Apalache lane):

| Model | Main | Obligation | Mode | Result | Time |
| --- | --- | --- | --- | --- | --- |
| rotation | `fixed` | `rotationInductive` (all four invariants + strengthening) | inductive | inductive | 3–10 s |
| rotation | `fix611` | `lockInductive` (single flight, no spurious rejection) | inductive | inductive | 2–3 s |
| rotation | `fix612` | `resurrectionInductive` | inductive | inductive | 2–3 s |
| rotation | `fix613` | `storeRefreshable` (no lock, no compare-and-rename: not inductive as stated) | bounded, 8 steps | bounded-safe | 38–42 s |
| pinning | `fixed` | `pinningInductive` (`noExpiredTokenRequest`, `requestReadyWhenStoreLive`) | inductive | inductive | 1 s |
| quota | `current` | `noStaleExhaustedInductive` | inductive | inductive | 1–3 s |
| quota | `fixed` | `quotaInductive` (both quota invariants) | inductive | inductive | 1 s |

The bounded depth of 8 covers the #613 counterexample (3 steps) and its after-recovery variant (7 steps).
As a check that the inductive obligation is not vacuous, removing the lock guard from the rotation model makes Apalache report a counterexample to `rotationInductive` (2 s).

Per-bug evidence files:

| Bug | Integration witness | Proof-model witness | Probe |
| --- | --- | --- | --- |
| #611 | `w611ConcurrentRefreshLoserFailsTest` | rotation `w611ConcurrentRefreshLoserFailsTest` | `issue_611_concurrent_refresh_loser_fails_test.fnl` |
| #612 | `w612RefreshResurrectsAfterLogoutTest` | rotation `w612RefreshResurrectsAfterLogoutTest` | `issue_612_refresh_resurrects_after_logout_test.fnl` |
| #613 | `w613CancelAfterCommitLosesRotationTest`, `w613NotExcusedAfterRecoveryTest` | rotation, same names | `issue_613_cancel_after_commit_loses_rotation_test.fnl` |
| #614 | `w614PinnedTokenExpires401Test` | pinning `w614PinnedTokenExpires401Test`, `w614PinnedSurvivesRefreshTest` | `issue_614_pinned_creds_expire_401_test.fnl` |
| #615 | `w615TmpWorldReadableTest` | none (no proof model) | `issue_615_tmp_auth_file_umask_readable_test.fnl` |
| #616 | `w616GetOverwrites429Test` | quota `w616GetOverwrites429Test` | `issue_616_usage_get_overwrites_limit_test.fnl` |

Probes live in `extensions/adapters/providers/openai/tests/`; each runs in well under a second.
The two-process races (#611, #612) are run as two coroutines in one Lua process sharing one temp `auth.json`, suspended at the same HTTP yield where the real processes would interleave; two real OS processes are not raced.

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
