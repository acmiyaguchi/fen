# Non-TUI presenters and headless outcomes

Model: [`model.qnt`](model.qnt).
Scope: every consumer of the agent event stream other than the TUI, and the outcome each reports.
One agent step (or two goal iterations) produces one shared stream: `llm-start`, text deltas, `provider-retry`, `llm-end`, then a natural stop (`assistant-stream-end`), a provider error (`:error`, including quota exhaustion with `error-details`), tool use (the next provider call, or the silent safety cap, or a second refusal under `:tool-choice :none`), or a cancel at a yield (aborted assistant, `:cancelled`).
After the step, `turn_lifecycle` emits `:agent-turn-complete`.
A `--continue` replay can put an earlier turn in `agent.messages` before the step starts.

The reference fold computes the true outcome of the step from how it ended and its own messages: `refStatus` (ok | error | cancelled), `refFinal` (the last assistant text only on ok), `refUsage` (this step's assistants), `refDetails`, and `refExit` (0 iff ok).
Each presenter's actual fold is modelled next to it, and the invariants compare the two.

Code: `extensions/adapters/presenters/{print,json,stdio,web,rpc,goal_headless}/init.fnl`, `extensions/adapters/presenters/web/ingest.fnl`, `packages/util/src/fen/util/{turn_result,headless_progress}.fnl`, `packages/fen/src/fen/{turn_lifecycle,interactive,session_control,session_cli,main}.fnl`, `extensions/behaviors/companions/goal/init.fnl` (`on-turn-complete`, `handle-success!`), `packages/core/src/fen/core/agent.fnl` (`step`, `step-loop`, `finish-stream-display`), `packages/core/src/fen/core/types.fnl` (`assistant-error`).

## Input assumptions

The environment actions are the user (a typed prompt starts step 1; goal starts step 2 only after an ok "continue" step, with no `:user` row), the provider (tokens, a transient retry, a natural stop, a provider error with or without `error-details`, tool use), the safety cap (`SAFETY = 2` provider calls per step), `:tool-choice :none` refusals, and a cancel at a yield.

They can produce: a `--continue` replay of one earlier turn (`initWith(true)`), up to 2 steps, 2 calls per step, 2 attempts per call, retries before or after text, and a GOAL_STATUS marker `continue` or `done` on an ok step.

They cannot produce: a typed prompt while a goal runs, steering or follow-up injection, compaction during the step, an ok step with no marker (the `outcome` proof model does cover that: it ends `blocked`), `:length` stops (treated as ok everywhere, see Open questions), SIGINT in headless modes, an rpc wire cancel or deadline (only the outcome of a cancel at a yield), or more than one text block per attempt.

## Evidence

| Claim | Kind | Where |
| --- | --- | --- |
| #619, #631, #632, #633, #634 in the model | counterexample | `current` rows; witnesses in `witnesses.qnt` and in `proofs/outcome`, `proofs/web-rows` |
| the same bugs in the code | confirmed | probes (per bug, below) |
| every consumer reports the step outcome under the fixes | bounded-safe at depth 0 over every input (exhaustive) | `proofs/outcome`: `fixed.allInvariants` |
| json/print/`session send` exit codes, final text, and error details are right today | exhaustive (depth 0) | `proofs/outcome`: `current` obligation |
| #634's fix alone fixes the lifecycle status and the goal exit | exhaustive (depth 0) | `proofs/outcome`: `fix634` obligation; `fix634.goalFinalTextMatches` stays violated (#633) |
| web rows never mix two steps today (#630 latent in web) | inductive | `proofs/web-rows`: `current.stepInv` |
| web rows satisfy every invariant under #631's fix | inductive | `proofs/web-rows`: `fixed.fixedInv` |
| integration `fixed` satisfies every invariant | sampled | `fixed.allInvariants` |
| the checks are not vacuous | mutants | `mutants.tsv` here and in both proof dirs |

## What holds

- `headlessExitMatchesStatus`: `fen --print`, the JSON presenter, and `fen session send --json` exit non-zero iff the step did not succeed, on every modelled path: error after streaming, quota error, cancel, safety cap, and refused tool turn.
  `turn_result.failed?` reads the last *assistant* message, so it does not inherit #609 from `turn_lifecycle`.
  A probe ran the real agent with the mock provider: after a `{:error "boom"}` turn the JSON presenter returned `code=1`, `final-text=nil`, and `stop-reason=error`.
- `headlessFinalTextMatches`, `headlessErrorDetailsMatch`: these presenters report the final text only on success, and report `error-details` only from a failed last assistant.
- `sendStatusMatchesOutcome`: `session send` reports `turn.status :error` whenever `failed?`, so it overrides the lifecycle's `:ok` for the cap and refusal paths.
  It also computes usage over the turn's own suffix (`copy-suffix`), which is correct.
- `stdioLinesSingleAttempt`, `stdioOkReplyShown`: stdio calls `finish-stream!` on `provider-retry`, `:error`, `:cancelled`, and `:user`, so neither network bug #629 nor #630 merges rows in stdio (see #631 for what stdio still shows).
- `webRowsSingleStep`: in web, a row from an error or cancelled turn is left open, but the next typed prompt inserts a `:user` row, and that row stops `find-streaming-row`.
  Goal, plan, and simplify turns submit with `emit-user? false`, but goal iterates only after an ok turn, which closes the row.
  So #630 is latent in web; the probe below reproduces the join only when no user row is inserted.
- Machine-readable stdout: the JSON presenter writes one blob (to stdout or `FEN_JSON_OUTPUT_PATH`), `headless_progress` and every `:error` handler write to stderr, and `session_cli.protocol-call` redirects `print`, `io.stdout`, and `os.exit` while it runs.
  No other non-interactive code writes to stdout during a turn (`grep` for `print` and `io.stdout`/`io.write` outside the TUI/CLI modules finds only the Codex login flow).
  This holds by inspection and is not modelled.

## Bugs

### #631: The web presenter joins a retried attempt's text onto the failed attempt's row (network #629, in web)

Counterexample (`webRowsSingleAttempt`, `webOkReplyShown`): `startStep → streamToken → retry → streamToken → streamToken → endStop`.
`web/ingest.fnl` handles `:provider-retry` in its generic branch: it appends a `provider-retry` row and leaves the open streaming row alone.
`find-streaming-row` walks back past non-barrier rows (`provider-retry`, `error`, `cancelled`, `queued`), so attempt 2's deltas append to attempt 1's row.
The transcript shows text that history never holds.
Stdio closes the line on retry, but it still prints the discarded fragment as its own `ai>` line, followed by the retry notice.
That is labelled, so it is not modelled as a violation, but a stdout reader still sees a partial answer that was never persisted.

Confirmed with a probe that sent bus events to the real web ingest and stdio `render-event`:

```
WEB-RETRY   user=q | assistant-text=Hello worHello world. | provider-retry=
WEB-ERR-AFTER  user=q | assistant-text=Partial ans(open) | error=boom
WEB-ERR-NEXT-WITH-USER  ... | error=boom | user=q2 | assistant-text=Fresh        (user row: no join)
WEB-CANCEL-NEXT-NO-USER user=q | assistant-text=Partial ansFresh | cancelled=   (latent N2)
STDIO>> ai> Hello wor\ninfo> provider retry 1/3: 500\nai> Hello world.\nai> Partial\nerr> boom\nai> Fresh\n
```

Witnesses: `reach631WebRetryDropsAttemptTest` (`witnesses.qnt`), `reach631RetryDropsAttemptTest` (`proofs/web-rows`).
Was reproduced by `issue_631_retry_joins_attempt_rows_test.fnl` (now the regression test below), the retry sequence through the real web ingest.

Fixed in #605: web's `ingest` clears the open streaming rows on `:provider-retry` (`drop-superseded-attempt!`) and closes them on `:error` and `:cancelled` (`extensions/adapters/presenters/web/tests/retry_drops_superseded_attempt_test.fnl`).

### #632: The rpc child exits `done` with code 0 and an `[error] …` final-text after a failed turn

Counterexample (`rpcExitMatchesStatus`, `rpcFinalTextMatches`): `startStep → endError`.
The rest of the paths are similar: `… endCap` and a refused finalize turn (`stop-reason "tool-use"`).
`turn-ended!` treats only a thrown Lua error as failure.
A provider error, quota exhaustion, safety cap, or second refusal advances `:turn-done` or `:final-turn-done`, which leads to `finish!`.
`finish!` emits `result` and then `exit done`, and `run` returns 0.
`final-text` is `types.assistant-text` of the last assistant, which for a provider error is the `"[error] …"` block that `types.assistant-error` builds, and `error-details` is not carried at all.
The in-tree parent hides this: `subagent/init.fnl` `result-failed?` re-classifies the run from `result.stop-reason` with `turn_result.failed?`.
Any other wire consumer, or a shell that checks the exit code, sees success.

Confirmed with a probe that drove the real rpc presenter, the cooperative agent, and the mock provider through the conformance kit's fake parent:

```
mock [{:error "usage_limit_reached: quota"}]; prompt "go"; wait turn-complete; close
RPC-ERR turn-complete.stop-reason= error  result.stop-reason= error
        result.final-text= [error] usage_limit_reached: quota  exit.status= done  exit.error= nil  code= 0
mock ["working" {:error "boom"}]; prompt; finalize
RPC-FINALIZE-ERR result.stop-reason= error  final-text= [error] boom  exit.status= done  code= 0
```

Witnesses: `w632RpcErrorExitsDoneTest`, `w632RpcCapExitsDoneTest` (`witnesses.qnt`), `w632RpcQuotaExitsDoneTest`, `w632RpcCapToolTextTest` (`proofs/outcome`).
Probe (reproduces): `extensions/adapters/presenters/rpc/tests/issue_632_failed_turn_exits_done_test.fnl`, the real rpc presenter, cooperative agent, and mock provider through a fake parent: after a quota error, `turn-complete` and `result` say `stop-reason error`, `final-text` starts with `[error] `, `result` has no `error-details`, `exit` is `done`, and `run` returns 0.

### #633: A goal that fails or is cancelled reports the previous iteration's text as its final text

Counterexample (`goalFinalTextMatches`): `startStep → … → endStop → finishStep(continue) → startStep → cancel → finishStep`, and the same with `endError`.
`on-turn-complete` sets `goal-state.last-result` only in `handle-success!`.
The `:cancelled` and `:error` branches leave it holding the last successful iteration's text.
`goal_headless` writes that stale text as JSON `final-text`, next to `status: "failure"` or `"blocked"`.
In plain mode it prints the stale text, which still ends in `GOAL_STATUS: continue`, followed by `GOAL_STATUS: error`.

Confirmed with a probe that ran the real goal companion and the real `goal_headless.run`, with `:agent-turn-complete` events emitted per tick:

```
iter1 {:status :ok :result "Iter one text.\nGOAL_STATUS: continue"}; iter2 {:status :error ...details usage_limit_reached}
GOAL-ERR    code= 1  goal.status= failure  final-text= Iter one text.\nGOAL_STATUS: continue  error-details.code= usage_limit_reached
iter2 {:status :cancelled}
GOAL-CANCEL code= 2  goal.status= blocked  final-text= Iter one text.\nGOAL_STATUS: continue
```

Witnesses: `reach633CancelClearsResultTest`, `w633ErrorKeepsStaleResultWith634Test` (`witnesses.qnt`), `reach633CancelClearsTextTest`, `w633ErrorKeepsPrevTextWith634Test` (`proofs/outcome`; the `With634` tests replay #633 alone on `fix634`).
Was reproduced, both paths, by `issue_633_failed_goal_reports_stale_text_test.fnl` (now the regression test below), the real goal companion and `goal_headless.run` with scripted `:agent-turn-complete` events.

Fixed in #605: the goal companion keeps `state.final-text`, set from a finished iteration and cleared when the iteration errors or is cancelled; `goal_headless` reports it, not `last-result` (`extensions/adapters/presenters/goal_headless/tests/failed_goal_has_no_final_text_test.fnl`).

### #619: The JSON presenter's `usage` and `messages` include `--continue` history

Same bug as [context #619](../context/FINDINGS.md), found independently; counted once in the overall tally.

Counterexample (`headlessUsageIsTurnUsage`): `init` with a replayed turn, then any step (`startStep → cancel` is shortest).
`json/init.fnl` passes all of `agent.messages` to `turn_result.sum-usage`, and puts all of them in `:messages`.
`session_lifecycle.start!` replays the previous session into `agent.messages` on `--continue`, and `main.fnl` does not forbid `--continue` with `--print` or `--presenter json`.
The blob then reports every earlier turn's tokens as this turn's.
`session send` gets this right by slicing from the replay count (`copy-suffix`).
`print` does not report usage, and `failed?` and `error-details` read only the last assistant, so the other fields are unaffected.

Confirmed with a probe that ran the real JSON presenter and real agent with the mock provider, after replaying one earlier turn of 1500 tokens:

```
JSON-CONTINUE replayed= 2  code= 0  usage.total= 1515.0  this-turn=15  messages= 4  final-text= new
JSON-ERR      code= 1  stop-reason= error  final-text= nil  error= [error] boom  usage.total= 1500.0
```

Witnesses: `w619ContinueUsageIncludesReplayTest` (`witnesses.qnt`), `w619ReplayedUsageTest` (`proofs/outcome`).
Probe (reproduces): `extensions/adapters/presenters/json/tests/issue_619_json_real_agent_counts_replay_test.fnl`, the real JSON presenter, agent, and mock provider, ok and error turns (the context domain's probe, `issue_619_json_usage_includes_replay_test.fnl`, stubs the agent).

An end-to-end CLI run was not possible here: `--provider mock` is rejected because the out-of-tree extension cannot register a provider (the mock is "off by default").
So the CLI half (`--continue` together with `--presenter json`) is confirmed by reading `main.fnl` and `session_lifecycle.fnl`.

### #634: A goal iteration that hits the safety cap exits 2 (`blocked`) instead of 1 (`failure`); downstream of #609

Counterexample (`goalExitMatches`, root cause `lifecycleStatusMatchesOutcome`): `startStep → … endToolUse → … endCap → finishStep`.
`turn_lifecycle.complete-event` reports `:ok` when the last message is a tool result (agent-loop #609).
Goal then runs `handle-success!` on `"[error] tool-call loop exceeded safety cap"`.
That text has no marker, so the goal ends `blocked` with "missing GOAL_STATUS marker", exits 2, and reports the error string as `final-text`.
`docs/sessions.md` says goal exits 1 for tool failures, and `--print` already treats the cap as a failure.
The same lifecycle status reaches every other `:agent-turn-complete` subscriber; the headless presenters are correct only because they ignore it and call `turn_result.failed?` themselves.

Confirmed by chaining two probes.
Agent-loop #610's probe showed `lifecycle status= ok` for a cap turn.
This domain's goal probe fed that event to the real goal companion and `goal_headless`:

```
GOAL-CAP code= 2  goal.status= blocked  reason= missing GOAL_STATUS marker  final-text= [error] tool-call loop exceeded safety cap
```

Witnesses: `reach634CapLifecycleErrorTest`, `reach634CapGoalErrorTest` (`witnesses.qnt`), `reach634CapGoalErrorTest`, `reach634RefusedGoalErrorTest` (`proofs/outcome`).
Was reproduced by `issue_634_cap_goal_exits_blocked_test.fnl` (now the regression test below): the real `turn_lifecycle.complete-event` over what the cap leaves (last message a tool result) says `:ok`, and the real goal companion and `goal_headless` then exit 2, `blocked`, "missing GOAL_STATUS marker", with the cap error as `final-text`. The cap itself is not run (1000 provider calls); agent-loop's #610 probe covers it.

Fixed in #605: `turn_lifecycle` reads the step's own `Outcome`, so a cap or refused turn is `:error` and the goal exits 1 (`extensions/adapters/presenters/goal_headless/tests/cap_goal_exits_failure_test.fnl`).

## Candidate fixes (named, `FIXES`)

Today's code carries #631, #633 and #634 (`current` has them; #619 and #632 are still open). Each fix is guarded by its issue number; instances `fix619`, `fix631`, `fix632`, `fix634` enable one fix each, and their rows show that fix makes its own issue's invariants hold.
#633's fix is not independent: on the cap path the wrong lifecycle status (#634) also puts the error text in `last-result`, so `goalFinalTextMatches` needs both; `fix634.goalFinalTextMatches` stays violated, which shows #633 is a separate bug.
`"631"` also closes web's open row on `:error` and `:cancelled` (the web twin of network #630, latent here).


- One step outcome, computed once: `turn_lifecycle` takes `{status, final-text, error-details}` from the step (agent-loop #609/#610 fix) instead of guessing from the last message.
  That fixes #634 and makes `lifecycleStatusMatchesOutcome` hold.
- #632: `finish!` emits `exit failed` (exit code 1) when `turn_result.failed?` holds for the run's last assistant.
  Alternatively, keep `exit done` but carry `status` and `error-details` in `result`, and only put model text in `final-text`.
- #633: on the `:error` and `:cancelled` branches, clear `goal-state.last-result`, or set it to the failed turn's result.
- #619: compute usage and messages over the suffix after the replay count, as `session send` does.
- #631: on `:provider-retry`, drop the open row's text in web (`fixed` models this), or have the agent emit an explicit attempt-boundary event (network's fix).

All invariants hold under `fixed` (`fixed.allInvariants`).

## Proof models

`proofs/outcome`: a common outcome alphabet (`ok`, `error`, `quota`, `cap`, `refused`, `cancelled`) and each consumer's output as a pure function of it plus the replay flag, the goal iteration, and the marker: json/print exit, final text, usage and details; `session send` status; rpc exit and final text; lifecycle status; goal status, exit, and final text.
`init` picks the input, `step` stutters, so depth 0 is every input (72 of them) and the result is exhaustive, not sampled.
It replaces re-running retries and tool loops per property; the integration model keeps those for conformance with the stream.

`proofs/web-rows`: the web transcript as scalars (open row, whether `find-streaming-row` reaches it, the step/call/attempt of its first text, sticky ghost flags), with typed prompts (a `:user` barrier) and goal iterations (no row, only after an ok step).

| Obligation | Result | Time |
| --- | --- | --- |
| `outcome` `fixed.allInvariants`, bounded 0 | bounded-safe (exhaustive) | 6 s |
| `outcome` `current` exit/final/details/send status, bounded 0 | bounded-safe (exhaustive) | 3 s |
| `outcome` `fix634` lifecycle and goal exit, bounded 0 | bounded-safe (exhaustive) | 2 s |
| `web-rows` `current.stepInv`, inductive | inductive | 4 s |
| `web-rows` `fixed.fixedInv`, inductive | inductive | 2 s |
| `web-rows` `fixed.allInvariants`, bounded 10 (the #631 counterexample is 6 steps) | bounded-safe | 1 s |

Negative controls (run once by hand): `outcome` `current.rpcExitMatchesStatus` at depth 0 and `web-rows` `current.fixedInv` inductive both give counterexamples.

## Open questions

- Interrupts in headless modes do not produce an outcome.
  `print`, `json`, and `session send` run the step on the main thread (`print`/`json` call `agent.step` outside a coroutine, so there is no cancel-fn), and no headless path installs a SIGINT or SIGTERM handler (`grep` finds signal handling only in the TUI, the subagent runner, and the bash tool).
  SIGINT therefore kills the process before the JSON blob, the `session send` document, or the goal outcome is written.
  That breaks "exactly one JSON document" for `session send`.
  Only the rpc child has a deadline (`FEN_WIRE_DEADLINE`) that produces a well-formed `exit timed-out`.
  This was traced through the code, not run.
- The rpc `result` has no `error-details`, so a subagent parent cannot see a child's quota-reset information.
  The wire doc does not promise the field, so this is a gap rather than a bug.
- `:length` (truncated) counts as success everywhere: print exits 0 and prints the truncated text.
  All presenters agree, so the model treats it as `ok`, but nobody has written down whether that is intended.
- Goal's `error-details` is emitted only for `status: "failure"`.
  A provider context-limit error becomes `blocked`, and its details are dropped.
- Stdio and web have no exit-code contract: `run` returns nil, so the process exits 0 even when every turn failed.
  Piped `fen --presenter stdio < prompts` therefore cannot detect failure.
- `docs/providers.md` documents `fen --extension extensions/adapters/providers/mock --provider mock`, but the installed v0.22.0 refuses it: "extension provider_mock cannot register privileged kind provider".

## Core

The stream does not need a separate interpretation in each presenter.
Every presenter here is a fold over the same small outcome: `{status: ok|error|cancelled, final-text?, error-details?, usage (this turn)}`, plus an exit code that is a pure function of `status`.
Today, four classifiers compute it independently:

- `turn_lifecycle` (last message, wrong for the cap and refusals)
- `turn_result.failed?` (last assistant, right), used again by `print`, which carries a private copy of `last-assistant`/`failed-turn?`
- the rpc child (wrong: "did not throw")
- goal (lifecycle status plus a sticky `last-result`)

The subagent parent then re-derives failure from the child's `stop-reason` to compensate.
If `agent.step` returned, or `turn_lifecycle` emitted, that canonical outcome once, the code below could be deleted, and each headless presenter would shrink to encoding the outcome in its own format:

- the duplicated `print` helpers
- `turn_lifecycle`'s message sniffing
- rpc's `turn-ended!`/`finish!` classification
- goal's `last-result` bookkeeping on failure
- the parent's `result-failed?`

The display presenters (web, stdio) need a second small rule from the network domain: only the last attempt counts, and every stream is closed exactly once.
