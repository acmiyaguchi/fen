# Provider network path

Model: [`model.qnt`](model.qnt).
Scope: one session's provider turns — `llm-start`, `retry.with-retry` attempts that stream deltas and hosted-tool events straight onto the bus, retry/backoff, finalize from the last attempt, `llm-end`, then `assistant-stream-end` (ok) or `:error`, plus cooperative cancel at any yield.
The TUI side is `ingest`, a pure `(tui, event) -> tui` step mirroring `extensions/adapters/presenters/tui/ingest.fnl`.

Code: `extensions/adapters/providers/shared/{retry,streaming}.fnl`, `packages/core/src/fen/core/agent.fnl` (`make-provider-stream-handler`, `step-loop`, `step`), `extensions/adapters/presenters/tui/ingest.fnl`.

## Input assumptions

The environment actions are the user (`startTurn`), the provider stream (`streamToken`, `hosted`), the transport (`attemptEnd`: complete, transient, permanent), the backoff timer (`backoffDone`), and Ctrl-C (`cancel`).

They can produce:

- up to 2 turns, 2 provider attempts per call, and 2 tokens per complete reply;
- a transient failure at any point of an attempt, including after text (a 429/5xx, a transient curl code, or a 2xx stream with no terminal event: the real code treats all three the same, and the producer conformance plays all three);
- a transient failure on the last attempt, which ends the turn with an error;
- a cancel at any yield of a streaming attempt or of the backoff.

They cannot produce:

- tool calls: one provider call per turn, so `llm-start`/`llm-end` are per turn here;
- more than one text block per attempt, or text after a hosted-tool item in the same attempt. A hosted item (`web_search_call`) ends the current block in the Responses reducer, so later text opens a new content index and a second TUI row, which the model does not represent. Hosted items therefore only happen before the attempt's first token (`hosted` needs `buf` empty, `streamToken` needs no open hosted item);
- thinking deltas, or a reply that is complete but invisible (a complete reply always has text, so `assistant-stream-end` is always emitted on success);
- a cancel after `llm-end` (at the yield after the message is appended) or before the first `llm-start`.

## Evidence

| Claim | Kind | Where |
| --- | --- | --- |
| #629, #630 in the model | counterexample | `current` rows in `checks.tsv`; witnesses in `witnesses.qnt` |
| #629, #630 in the code | confirmed | probes (below), and the producer conformance: the real chain matches `current` step by step, bugs included |
| `fixed` satisfies every invariant | sampled | `fixed.allInvariants` |
| the stream-display contract holds under both fixes | inductive | `proofs/stream-rows`: `fixed.inductiveInv` |
| each fix is independent | sampled + counterexample | `fix629`/`fix630` rows; `fix630.okReplyDisplayed` is still violated (#629): `okReplyDisplayed` needs both fixes |
| the checks are not vacuous | mutants | `mutants.tsv` here and in `proofs/stream-rows` |

## Bugs

### #629: A mid-stream retry leaves the failed attempt's text on screen

Counterexample (`noSupersededText`, `okReplyDisplayed`): `startTurn → streamToken → transient → backoffDone → …`.
Each attempt gets a fresh parser and state, and the persisted assistant message is built from the last attempt only, but deltas from every attempt reach the bus.
`:provider-retry` clears hosted tools (#574) and leaves the open streaming row alone, so attempt 2's deltas append to attempt 1's text.

Confirmed against real ingest: deltas `"Hello wor"`, `:provider-retry`, `"Hello world."`, `:llm-end`, `:assistant-stream-end` render one row `"Hello worHello world."` while history holds `"Hello world."`.

Witnesses: `w629RetryKeepsSupersededTextTest`, `w629NotFixedBy630Test` (`witnesses.qnt`), and `w629RetryKeepsSupersededTextTest` in `proofs/stream-rows`.
Probes (both reproduce):

- `extensions/adapters/presenters/tui/tests/issue_629_retry_keeps_superseded_text_test.fnl`: the event sequence above through the real TUI ingest.
- `extensions/adapters/providers/shared/tests/issue_629_attempt_deltas_reach_bus_test.fnl`: the real `streaming.complete-streaming` and `retry.with-retry` over a stubbed HTTP backend. Attempt 1's delta and attempt 2's delta reach `on-event` on content index 1 with only `:provider-retry` between them, while the returned message holds only attempt 2's text. This probe flips if the producer gains an attempt-boundary event (the alternative fix), not if only the TUI fix lands.

### #630: After an error or cancel, the next turn's text joins the dead turn's row

Counterexample (`rowsSingleTurn`, `noOpenRowWhenIdle`): `startTurn → streamToken → cancel → startTurn → streamToken`.
The agent emits no `assistant-stream-end` on the error or cancel paths, and neither the `:error` nor the `:cancelled` handler closes `streaming-assistant-rows`; only `/new` resets them.
The next turn's first delta for the same content index appends to the stale open row.

Confirmed against real ingest for both paths: the transcript renders `"Partial ansFresh answer."` above the error/cancelled row and the new user row.

Witnesses: `w630CancelLeavesRowOpenTest`, `w630NextTurnJoinsDeadRowTest` (`witnesses.qnt`), and `w630NextTurnJoinsDeadRowTest`, `w630ErrorLeavesRowOpenTest` in `proofs/stream-rows`.
Probe (reproduces, both paths): `extensions/adapters/presenters/tui/tests/issue_630_dead_turn_row_reused_test.fnl`.

## Candidate fixes (named, `FIXES`)

- `"629"`: `:provider-retry` drops the open row's text (instance `fix629`).
- `"630"`: `:error` and `:cancelled` close open streaming rows (instance `fix630`).

All invariants hold under `fixed` (both).
`fix629` alone makes `noSupersededText` hold; `fix630` alone makes `rowsSingleTurn` and `noOpenRowWhenIdle` hold; `okReplyDisplayed` needs both.
An alternative that keeps the rule in one place: the agent always emits `assistant-stream-end` (with a reason) when a provider call ends for any reason, so every presenter gets the close.

## Conformance

`conform.sh` generates 200 traces of `step` plus 100 of `stepNoCancel` (the same actions without cancel: cancel is enabled in every busy state, so plain traces rarely complete a turn; the extra batch has about 22 completed turns and 13 retried completions per 100) and runs two replays over each:

- `replay_test.fnl`: the model's `emitted` events through the real TUI ingest; the final transcript rows and open-row count must equal the model's.
  Its first run caught a model error, not a code bug: the real ingest adds an `:info` row when a hosted tool ends, which the model had omitted.
- `producer_test.fnl`: the real event producer.
  Each trace's actions become a scripted HTTP backend (via `fen.testing.stub-http!`) under the real chain `turn_submit.submit!` → `agent.step` (cooperative, in a coroutine) → `llm.complete` → `openai_responses` → `provider_shared.streaming` → `retry.with-retry` → `fen.util.http`, with the agent's events on the real bus and the real TUI subscribed.
  `streamToken` is a `response.output_text.delta` SSE chunk (opening the message item on the attempt's first token), `hosted` a `web_search_call` item added or done, `complete` the item done plus `response.completed`, `transient` one of a 500, curl code 56, or a 2xx stream with no terminal event, `permanent` a 400, `backoffDone` the retry sleep's yield, and `cancel` sets the turn's cancel flag at the next cooperative yield (as Ctrl-C does). No network, no credentials.
  Per trace it checks that the events the code emits, projected onto the model's alphabet, equal the model's `emitted`; that after every model step the real TUI state (rows, open streaming rows, hosted-tool flag, retrying flag) equals the model's `tui`; and that the assistant history equals the model's `history`.
  The step-by-step comparison catches what the final one cannot: ignoring the real retrying flag fails 9 of 20 traces, while every final state has it cleared.

`conform.sh --negative` replays the `fixed` instance, whose transcripts differ from today's code, and must fail (about 170 of 300 producer traces diverge).
The runner's exit status is kept (no pipeline); the whole check takes about 6 s.
The two harness changes it needed in the model: hosted items only before an attempt's text (see Input assumptions), and the `stepNoCancel` action.

## Proof model: `proofs/stream-rows`

The contract alone, in scalars: the open row, the turn of its first text, the lowest attempt of the current turn's text in it, the attempt's token count, the hosted and retrying flags, and three sticky ghost flags (`mixed`, `stale`, `badOk`) set when a violation happens, so no invariant rebuilds a transcript.
`current` reproduces both bugs (violated rows, witnesses); `fixed` has an inductive strengthening `inductiveInv` (type bounds, "a row with text is open, from this turn and this attempt", "this attempt's tokens are what the open row shows", hosted and retry bookkeeping).

| Obligation | Result | Time |
| --- | --- | --- |
| `fixed.inductiveInv`, inductive | inductive | 3 s |
| `fixed.allInvariants`, bounded 12 (both counterexamples are at most 7 steps) | bounded-safe | 3 s |

As a negative control, `current.inductiveInv` gives a counterexample.

## Core

The essential contract is small: *a stream is a sequence of attempts; only the last attempt's content is real; every stream is closed exactly once*.
Today that rule is spread across the provider skeleton (fresh state per attempt), the agent (stream-end only on success), and each presenter (ad hoc clears on retry).
Making "attempt boundary" and "stream close" explicit bus events would let every presenter be a dumb fold.
