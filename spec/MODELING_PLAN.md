# Modeling plan: concurrency boundaries

Model first, then code. Each item is one PR on its own branch off `main` (never stacked).
Each PR passes `make check`, `scripts/spec/check.sh` (mutants killed) and `scripts/spec/verify.sh` (no timeouts).

Rules:

- Model commits do not touch code; code commits do not weaken a model.
- Every bug fix lands with the test that fails without it.
- A proof that will not finish within its timeout is restructured (state-predicate refinement, smaller domains), not given a longer timeout.
- An item may be deferred only with a written reason in the table below.

| # | Item | Model | Invariant (one sentence) | Status |
|---|------|-------|--------------------------|--------|
| 1 | Serve refines the holder | `spec/serve` against `holderAbstract` in `spec/core/tasks/proofs/holder` | Every serve step maps to a holder step or a stutter; the old mailbox half of `requestsAbstract` is deleted. | todo |
| 2 | RPC ref accounting | extend `spec/wire` with the session holder (`presenters/rpc`, `util/wire_session`) | Every accepted control ref gets exactly one terminal notice: injected, started, refused, released or cleared. | todo |
| 3 | Tool-call pairing | already proved: `agent-loop` (`paired`), `sessions` (`compactionCutKeepsPairs`) | Every tool use has exactly one result before the next request, across cancel, compact and handoff. | audit: check that `run-exclusive!` compaction and handoff still match the models; model only if they diverge |
| 4 | Runtime shell (L3) | new `spec/core/tasks/proofs/shell` refining `holder` | A job runs only while it holds the session; an abandoned coroutine is never resumed; the scheduler runs only on idle ticks; `:spawn-failed` always releases. | deferred: the shell code changed heavily in #686; model it after about a week of real use (from 2026-11-01) so field bugs show where it needs detail, instead of modeling moving code twice |
| 5 | Fenced subagent and side-chat cancel | extend `spec/core/tasks/proofs/lease` with nested holders; `spec/subagents`, `spec/tui-turns` | A cancel addressed to an earlier holder never affects a later one. | todo |
| 6 | Reload phases | `spec/core/contrib` / new reload proof | A cancel during `/reload` leaves only the old code or only the new code running. | todo; may be deferred if reload is untouched |
| 7 | Liveness target | bounded lease model for TLC | Every requested start or exclusive job eventually runs, under fairness. | todo; `make check-liveness`, kept out of `make check` |
