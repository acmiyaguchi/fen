# Provider network path

Model: [`model.qnt`](model.qnt).
Scope: one session's provider turns — `llm-start`, `retry.with-retry` attempts that stream deltas and hosted-tool events straight onto the bus, retry/backoff, finalize from the last attempt, `llm-end`, then `assistant-stream-end` (ok) or `:error`, plus cooperative cancel at any yield.
The TUI side is `ingest`, a pure `(tui, event) -> tui` step mirroring `extensions/adapters/presenters/tui/ingest.fnl`.

Code: `extensions/adapters/providers/shared/{retry,streaming}.fnl`, `packages/core/src/fen/core/agent.fnl` (`make-provider-stream-handler`, `step-loop`, `step`), `extensions/adapters/presenters/tui/ingest.fnl`.

## Bugs

### N1. A mid-stream retry leaves the failed attempt's text on screen

Counterexample (`noSupersededText`, `okReplyDisplayed`): `startTurn → streamToken → transient → backoffDone → …`.
Each attempt gets a fresh parser and state, and the persisted assistant message is built from the last attempt only, but deltas from every attempt reach the bus.
`:provider-retry` clears hosted tools (#574) and leaves the open streaming row alone, so attempt 2's deltas append to attempt 1's text.

Confirmed against real ingest: deltas `"Hello wor"`, `:provider-retry`, `"Hello world."`, `:llm-end`, `:assistant-stream-end` render one row `"Hello worHello world."` while history holds `"Hello world."`.

### N2. After an error or cancel, the next turn's text joins the dead turn's row

Counterexample (`rowsSingleTurn`, `noOpenRowWhenIdle`): `startTurn → streamToken → cancel → startTurn → streamToken`.
The agent emits no `assistant-stream-end` on the error or cancel paths, and neither the `:error` nor the `:cancelled` handler closes `streaming-assistant-rows`; only `/new` resets them.
The next turn's first delta for the same content index appends to the stale open row.

Confirmed against real ingest for both paths: the transcript renders `"Partial ansFresh answer."` above the error/cancelled row and the new user row.

## Candidate fix (modelled as `fixed`)

- `:provider-retry` drops the open row's text.
- `:error` and `:cancelled` close open streaming rows.

All invariants hold under `fixed`.
An alternative that keeps the rule in one place: the agent always emits `assistant-stream-end` (with a reason) when a provider call ends for any reason, so every presenter gets the close.

## Core

The essential contract is small: *a stream is a sequence of attempts; only the last attempt's content is real; every stream is closed exactly once*.
Today that rule is spread across the provider skeleton (fresh state per attempt), the agent (stream-end only on success), and each presenter (ad hoc clears on retry).
Making "attempt boundary" and "stream close" explicit bus events would let every presenter be a dumb fold.
