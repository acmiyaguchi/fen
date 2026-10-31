# Extension registry, event bus, and /reload

Model: [`model.qnt`](model.qnt).
Scope: two extensions in discovery order, each owning commands (one name shared by both), an array tool, a bus subscription, and a prompt fragment.
Owner `A` plays the sessions extension, so it owns `/reload`.
Actions: edit a source to `ok` / `badModule` (a reload-module fails to load, such as a syntax error) / `badRegister` (the register fn raises), `/reload` (all extensions), `/reload-extension <o>`, a turn that snapshots the agent's tools and appends messages, the `extension` tool's `reload` action during that turn, an event emit whose first handler may unload another owner, and registering a contribution with no callable.

Code: `packages/core/src/fen/core/extensions/loader/init.fnl` (`load-module-spec!`, `load!`, `reload-extension!`), `loader/reload.fnl` (`clear-reload-modules!`, `change-summary`, `reload-module-in-place!`), `register/init.fnl` and the per-kind modules (`util.set-tagged!` for singleton dicts, `util.add-tagged!` / `contribution.fnl` / `prompt.fnl` for arrays), `events.fnl` (`emit`, `dispatch-bucket`), `extensions/behaviors/actions/sessions/commands/session.fnl` (`perform-reload!`), `extensions/behaviors/inspectors/extensions/commands/extension.fnl` (`perform-extension-reload!`, `execute-tool`), `packages/fen/src/fen/{interactive,turn_submit,session_lifecycle}.fnl`.

## Input assumptions

What the environment actions can produce: any interleaving of source edits (each owner's source becomes `ok`, `badModule`, or `badRegister`), `/reload` (only at idle and only while the `reload` command is registered), `/reload-extension <o>` at idle for an owner the loader knows, turns that start, append messages and end, the `extension` tool's `reload` during a turn, an emit whose first handler unloads `B` (at idle, like the idle-only disable commands), and a contribution registered without its callable.

What they cannot produce: more than two owners or one shared name per kind; first-party fail-fast errors on reload (noted under #624, not modelled); a yield in the middle of `clear-reload-modules!` (see Open questions); nested emits; the TUI's reload-last ordering; more than 3 unflushed messages per turn.

## Bugs

### #624: A module error during `/reload` aborts the pass after the extension was already unregistered

Counterexample (`reloadVisitsEveryOwner`, `attemptedOwnerListed`, `reloadCommandAvailable`): `init → edit(A, badModule) → reloadAll`.
`load-module-spec!` calls `unregister-by-owner` first, then `clear-reload-modules!`, which `error`s on a failed module outside any pcall.
`unregister-by-owner` also deletes the `state.extensions` record, so the extension is no longer listed at all, not even with `:error`.
The raise escapes `load!`, so later extensions are never reloaded, and it escapes `perform-reload!`, so the TUI reload, provider re-registration, and agent rebuild are skipped too.
When the broken extension owns `/reload` (sessions) or `/extensions`, the recovery commands disappear and only a restart helps. `/extensions disable` already refuses to disable those owners for exactly this reason.
`reload-module-in-place!` had already put the old module back in `package.loaded`, so re-registering the previous version was possible.
A related path raises the same way: a first-party extension whose register fn raises on reload gets `record-spec-error!` (all its registrations dropped), and then `load!` raises its first-party fail-fast error, which aborts `perform-reload!` at the same point.

Former witnesses (removed once the fix landed): `w624ModuleErrorAbortsPassTest` ([`witnesses.qnt`](witnesses.qnt) and the [`contrib`](proofs/contrib/) proof model).
Probe: `packages/core/tests/extensions/loader/reload_module_error_keeps_stale_test.fnl` (regression test).

Confirmed (the original throwaway probe, rebuilt as the probe above): alpha (`reload-modules = {alpha_helper, alpha}`) and beta loaded; then alpha_helper raises and beta changes to register `beta-v2`:

```
before:	alpha	beta	loaded	1
reload ok?	false	.../loader/reload.fnl:175: reload probe.alpha_helper: ...: helper.fnl:3: unexpected closing delimiter
after: alpha-cmd owner	nil	alpha record	nil	tick handlers	0	beta-v1	beta	beta-v2	nil
reload-extension! alpha: pcall ok?	false	.../loader/reload.fnl:175: reload probe.alpha_helper: ...
```

alpha lost its command, its bus handler, and its status record, and beta was never reloaded.
`reload-extension!` raises instead of returning `(false err)` as documented.

Fixed in #605: `load-module-spec!` and `load-path-spec!` stage the owner's new contribution set (`contrib.begin!`) and swap it in on success. A failed module, require, or register fn rolls back to the previous set, marks the owner `:stale` with the error, and returns `(false err)`; `load!` continues with the next owner (the first-party fail-fast error is still raised after the pass).

### #625: A failed module's fingerprint is committed, so the next `/reload` silently brings back the old code as `:loaded`

Counterexample (`loadedStatusTruthful`): `init → edit(B, badModule) → reloadAll → reloadAll`.
`clear-reload-modules!` calls `change-summary`, which commits every fingerprint before any module runs.
After the failure in #624, the next reload sees no change, skips the broken module, `require` returns the old table that was put back in `package.loaded`, and registration succeeds.
The extension reports `:loaded` with 0 changed while the source on disk is still broken.
Core reload already does this correctly: `reload-core!` commits a fingerprint only after the module reloads and keeps `reload-core-failures` so it retries next time.

Former witnesses (removed once the fix landed): `w625FingerprintRetrySkippedTest` (integration model) and `w625FailedFingerprintCommittedTest` ([`fingerprint`](proofs/fingerprint/) proof model).
Probe: `packages/core/tests/extensions/loader/failed_module_fingerprint_not_committed_test.fnl` (regression test; `checksum.module-fingerprint` is patched to return controlled fingerprints).

Confirmed (the original throwaway probe, rebuilt as the probe above, with the checksum backend stubbed to return controlled fingerprints):

```
loaded:	alpha
reload #1 pcall:	false	.../loader/reload.fnl:175: reload probe.alpha: ...: alpha.fnl:9: unknown identifier
after #1: alpha-v1	nil	record	nil
reload #2:	true	nil
after #2: alpha-v1	alpha	status	loaded	(source on disk is still the broken v2)
```

Fixed in #605: `change-summary` only observes fingerprints; `clear-reload-modules!` and the loader commit one after the module reloads (or the extension registers) successfully, so a broken module is retried by the next `/reload`.

### #626: Reloading or failing one extension makes the registry differ from a fresh start

Counterexample (`registryMatchesFreshStart`): `init → reloadOne(A)`.
Singleton kinds (commands, providers, auth/session backends) use `set-tagged!`, so the last writer wins, and `unregister-by-owner` drops only the winner's record.
At a fresh start the winner of a shared name is the extension loaded last.
- `/reload-extension` of the shadowed owner moves the name to that owner.
- When the winner's reload fails, the name disappears entirely, even though the other owner still claims it.

Array kinds append, so a reloaded owner moves to the end of the bucket. That changes:
- which duplicate-named tool `find-tool-record` picks (first match),
- the order of prompt fragments that share the default `:order 90` (by `seq`), which also changes the system-prompt bytes and therefore the prompt-cache prefix,
- before-tool hook order and bus handler order.

A full `/reload` replays discovery order, so it restores fresh-start order unless #624 cuts the pass short. The TUI is the exception: it is reloaded last on purpose (see Open questions).

Former witnesses (removed once the fix landed): `w626ReloadOneMovesWinnerTest` and `w626UnloadDropsSharedNameTest` (integration model), `w626ReloadOneMovesWinnerTest` and `w626DisableDropsSharedNameTest` ([`contrib`](proofs/contrib/)).
Probe: `packages/core/tests/extensions/loader/reload_one_owner_matches_fresh_start_test.fnl` (regression test, both cases: the shadowed owner reloaded, and the failing winner).

Confirmed (the original throwaway probe, rebuilt as the probe above): alpha and beta both register command `:dup`, tool `:dup_tool`, and a default-order prompt fragment:

```
fresh: /dup owner	beta	first dup_tool	alpha	prompt	frag-alpha||frag-beta
after reload-extension alpha: /dup owner	alpha	first dup_tool	beta	prompt	frag-beta||frag-alpha
fresh2: /dup owner	beta
reload-extension beta:	false	...: beta register boom
after beta failure: /dup owner	nil	(fresh start with beta failing would give alpha)
```

Fixed in #605: Registrations live in per-owner sets (`fen.core.extensions.contrib`); every registry view (including the bus buckets) is a fold over owners in load rank, and a rank is never reassigned, so `/reload-extension` and a failed reload keep fresh-start order and shared-name winners.

### #627: The model-facing `extension` tool reloads synchronously mid-turn

Counterexamples:
- `noRegistrySwapDuringTurn`: `init → startTurn → midTurnReload`
- `turnToolsLive`: `init → edit(A, badModule) → startTurn → midTurnReload`
- `turnMessagesPersisted`: `init → startTurn → midTurnReload → turnAppend → endTurn`

The documented contract is that the `reload` tool only queues and runs at the idle boundary ("so modules never swap during a stream or tool call", `interactive.fnl`).
The `extension` tool's `action=reload` skips that contract: `execute-tool` calls `perform-extension-reload!`, which runs `reload-extension!` and replaces `state.agent` while the turn is still running.
The turn keeps stepping the agent `turn_submit` captured, using its `agent.tools` snapshot from `make-agent`. That snapshot can still hold tools whose owner was just unregistered (#624 makes this likely), and it cannot see the new tools.
`session_lifecycle`'s `:message-appended` bridge flushes only when `ev.agent == state.agent`, so the rest of that turn's tool results and reply are not persisted.
They are written only when the replacement agent appends its first message. Nothing flushes at shutdown, so quitting right after the turn loses them from the session JSONL.

Former witnesses (removed once the fix landed): `w627MidTurnAgentSwapTest`, `w627TurnToolsUnregisteredTest`, `w627TurnMessagesUnflushedTest` (integration and [`turn-identity`](proofs/turn-identity/) models).
Probe: `extensions/behaviors/inspectors/extensions/tests/extension_tool_reload_deferred_test.fnl` (regression test). It is the closest observable behaviour, not a real turn: the real `extension` tool and `session_lifecycle` run against a busy run-state stub, and `state.reload-extension` is a stub that counts calls and runs the real `unregister-by-owner`. The `turn_submit`/`agent-step` path and the shutdown-without-flush loss remain a line trace.

Confirmed (the original throwaway probe, rebuilt as the probe above): the real `extension` tool runs against a busy run-state stub with the real `session_lifecycle.install!`:

```
tool is-error?	false	reloads ran while busy?	true	1	state.agent	new	old agent still has	doomed	messages shared	true
session_lifecycle loadable	true
flushes after old-agent message-appended	0
```

The turn path (`turn_submit.start!` passes `state.agent` once to `agent-step`; `append-message!` emits `{:agent agent}`; `M.close!` does not flush) was traced line by line.

Fixed in #605: The `extension` tool's `reload` action enqueues a `{:scope :extension :name ..}` `reload_request`, drained at the idle boundary as `/reload-extension <name>`.

### #628: Tool registration does not validate `:execute`

Counterexample (`registeredCallablesPresent`): `init → registerMalformed(tool)`.
`:command` requires `{:handler fn}`, `:hook` requires `{:before-tool fn}`, and `:provider` requires `:complete`, but `:tool` checks only `:name` and `:exposure`.
A tool without `:execute` is advertised to the model and fails only when called, with `attempt to call a nil value (field 'execute')`.
The agent's pcall turns that into a tool error, so the impact is low (a confusing late failure), but the validation is not uniform.

Former witnesses (removed once the fix landed): `w628ToolWithoutExecuteTest` (integration model) and `w628ToolWithoutExecuteAcceptedTest` ([`validation`](proofs/validation/)).
Probe: `packages/core/tests/extensions/tool_requires_execute_test.fnl` (regression test; `:command` and `:hook` without callables are the rejected controls).

Confirmed (the original throwaway probe, rebuilt as the probe above):

```
register ok?	true
command w/o handler ok?	false	.../register/command.fnl:11: register :command requires {:handler fn}
hook w/o fn ok?	false	.../register/hook.fnl:15: register :hook requires {:before-tool fn}
coop execute-call raises?	true	.../fen/core/tools.fnl:146: attempt to call a nil value (field 'execute')
```

Fixed in #605: `register :tool` requires `:execute` to be a function.

## Holds

`busDeliversOncePerLiveSubscriber` (sampled): `emit` snapshots the bucket and delivers only to snapshot entries still in the live bucket.
A handler that unloads another owner mid-dispatch therefore stops delivery to it, and handlers added mid-emit wait for the next emit.
Each subscription gets an event at most once, and an unregistered owner never gets one.

## Candidate fixes (named: `FIXES`)

The model takes `const FIXES: Set[str]`; `current` and `fixed` enable all five, and `fix624` … `fix628` one each. Each fix makes its own issue's rows hold on its own (sampled, `checks.tsv`):

| Fix | Rows it makes hold alone |
| --- | --- |
| `624` transactional per-owner reload | `reloadVisitsEveryOwner`, `attemptedOwnerListed`, `reloadCommandAvailable` |
| `625` fingerprint committed only on success | `loadedStatusTruthful` |
| `626` views derived from per-owner sets | `registryMatchesFreshStart` |
| `627` `extension` tool reload deferred to idle | `noRegistrySwapDuringTurn`, `turnToolsLive`, `turnMessagesPersisted` |
| `628` `:execute` validated | `registeredCallablesPresent` |

- Make per-owner reload transactional:
  - pcall the whole module-reload-plus-register step.
  - Register the new version into a staging set, then swap it in on success.
  - On failure keep the previous registrations and mark the owner `:stale` with the error, so it is never `:none`.
  - Keep going with the next extension.
- Store contributions per owner and derive every view (singleton dicts, arrays, the bus bucket) by folding owners in discovery order. A shared name then resolves to the same winner as a fresh start, and unloading one owner exposes the other owner's claim again.
- Commit a module fingerprint only after it reloads successfully, as `reload-core!` already does.
- Route the `extension` tool's `reload` through `reload_request` (deferred to idle), like the `reload` tool.
- Validate `:execute` as a function in `register :tool`.

All invariants hold under `fixed` (sampled; 60k samples × 30 steps when first checked, 20k × 20 in `check-spec`).
Reachability witnesses show the fixed design still reaches a failed reload kept as `:stale` with the pass continuing, a repair back to `:loaded`, a retried (not skipped) broken module, fresh-start order after `/reload-extension`, the other owner's claim exposed by an unload, and a mid-turn reload queued, the turn's messages flushed, and the reload drained at idle.

Mutants ([`mutants.tsv`](mutants.tsv)), each caught by `check-spec`: in-place registry mutation instead of derived views (`registryMatchesFreshStart`), a failed reload marking the owner `:error` instead of `:stale` (`reloadCommandAvailable`), the fingerprint committed before the module runs again (`loadedStatusTruthful`), the synchronous mid-turn reload (`noRegistrySwapDuringTurn`), and the `:execute` check removed (`registeredCallablesPresent`).

## Proof models

One per contract, under [`proofs/`](proofs/), each with a `current` instance whose rows are `violated` with witnesses and a `fixed` instance proved by `verify-spec` (Apalache 0.56.1, one lane, `-Xmx3g`, shared machine):

| Model | Issues | State | Obligation | Result | Time |
| --- | --- | --- | --- | --- | --- |
| [`contrib`](proofs/contrib/model.qnt) | #624, #626 | two owners' status and source; the registry as four scalars (shared-name winner, `reload` and `bcmd` owners, bucket order); `/reload` as one `passStep` per owner with a next-owner pointer and visited flags | `fixed.contribInductive` | inductive | 7 s |
| [`fingerprint`](proofs/fingerprint/model.qnt) | #625 | one module's source, committed flag, status, source seen by the last attempt | `fixed.fingerprintInductive` | inductive | 1 s |
| [`turn-identity`](proofs/turn-identity/model.qnt) | #627 | phase, agent identity, B's source and tool, the turn's tool snapshot, unflushed flag, deferred request | `fixed.turnIdentityInductive` | inductive | 1 s |
| [`validation`](proofs/validation/model.qnt) | #628 | none: a finite function check over every kind and both inputs | `fixed.registeredCallablesPresent wellFormedAccepted`, 0 steps | bounded-safe (the whole input space) | 0 s |

`contrib` also has `fix624` and `fix626` instances, so ordering (#626) and rollback (#624) are checked one at a time there as well.
A first version of `contrib` evaluated the whole `/reload` pass in one step, with nested record updates; Apalache took 173 s and later ran out of a 3 GB heap. Splitting the pass into one step per owner and keeping the state in scalar variables brought it to 7 s.

## Open questions

- `clear-reload-modules!` yields between modules while the owner is unregistered. Presenter ticks in that window see the owner's status items, panels, and commands missing, and its bus handlers miss events. Not probed.
- `/reload` reloads the TUI last (`skip-names {:tui true}`, then `only-names {:tui true}`), so its controls, handlers, and commands move to the end of their buckets, while a fresh start places them in discovery order. This matters only if another extension shares a TUI control key or command name. Not checked.
- `emit {:type :*}` dispatches the `:*` bucket twice, because the type bucket and the wildcard bucket are the same table. Wildcard subscribers then get the event twice. Found by reading the code; it needs a caller to emit `:*`, which none does.
- `util.deep-copy` has no cycle guard, so a self-referential spec overflows the stack inside the register pcall. It is reported as an extension error, not a crash.
- The `state.fnl` doc says `tools-extra` is "appended to the agent's base tool set each step", but `agent.tools` is a snapshot taken at `make-agent`. This doc drift hides #627.

## Core

The essential contract is: *the registry is a pure function of (load order, the set of working owners, each owner's last good contribution set)*, and *a reload swaps one owner's set atomically, only at an idle boundary*.
Today registration mutates shared dicts and arrays in place: unregister first, re-register later, and a raise in between leaves the half-removed state.
Three things then each patch a different symptom: collision rules emerge from mutation order, the fingerprint cache runs on its own timeline, and the mid-turn tool path skips the idle queue.
A per-owner map `owner -> {version, contributions, status}` with derived views would collapse unregister-by-owner, collision resolution, cleanup on failure, and list caching (`registry-version`) into one fold. The bus is already correct, and the same snapshot-then-live-check rule would carry over unchanged.
