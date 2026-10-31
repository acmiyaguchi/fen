# Design models

Executable [Quint](https://quint-lang.org) models of fen's core contracts.
Each model states what a subsystem is supposed to guarantee, checks the current design against it by simulation, and records the counterexamples it finds.
The goal is twofold: catch design bugs that live in interleavings (retries, cancels, reloads, two processes) rather than in any one function, and name the small core each subsystem actually needs.

These are design artifacts, not runtime code.
Quint is a dev-only dependency (in `nix develop`); nothing here ships in the binary.

## Running

```sh
nix develop          # provides quint
make check-spec      # every domain
make check-spec SPECS=spec/network
```

`check-spec` is not part of `make check`.

## Layout

Each domain is one directory:

| File | Purpose |
| --- | --- |
| `model.qnt` | The model. Pure step functions where the code has them; actions for the environment (network, user, clock, other process). |
| `checks.tsv` | `main<TAB>invariant<TAB>holds\|violated`, run by `scripts/spec/check.sh`. |
| `FINDINGS.md` | Scope, code it mirrors, bugs (counterexample + how it was confirmed against real code), candidate fixes, and the domain's minimal core. |

A `violated` row records a known bug in the current design: the check passes while the model still finds a counterexample.
When the code is fixed, update the model and flip the row to `holds`.
Where a candidate fix is modelled, a `fixed` instance (`module fixed { import <model>(FIXED = true).* }`) carries it and should satisfy every invariant.

## Conformance

A model that is never compared with the code drifts into a second, stale description.
A domain may ship `conform.sh`, which `check-spec` runs after the domain's checks:

| Domain | Kind | What it compares |
| --- | --- | --- |
| [wire](wire/conform.qnt) | table | Every (state, control) and (state, event) pair of the model's `decide`/`advance` against `fen.util.wire_session` (`scripts/spec/conform-wire.fnl`). |
| [network](network/replay_test.fnl) | trace replay | 200 Quint traces of the `current` model, each event sequence fed through the real TUI ingest; the transcript must equal the model's. |

Conformance pins the model to today's code, bugs included.
A fix therefore changes both sides in one PR: e.g. the network streaming-row fix flips `SPEC_NETWORK_MAIN` in `network/conform.sh` to `fixed` (today 113 of 200 `fixed` traces diverge from the code, as they should).

## Conventions

- Model the code as it is, cite the files it mirrors, and keep models small: 2–3 turns, attempts, or tabs are enough to expose interleavings.
- A bug counts when the model finds it **and** it is confirmed against the real code (a throwaway Busted probe, a REPL run, or a line-by-line trace through the source).
  Model-only suspicions go under "Open questions" in `FINDINGS.md`.
- Invariants are named for the property (`noOpenRowWhenIdle`), not the bug.
- Quint 0.33 gotchas: parameterised actions need a return type (`action a(x: int): bool = ...`); strings do not concatenate; ITF trace keys are namespaced (`<main>::<module>::<var>`).
- Shortest counterexample: rerun `quint run --main=M --invariant=I --max-steps=N --out-itf=t.json model.qnt` with increasing `N`.

## Domains

Bug IDs are prefixed per domain so they stay unique across the tree.

| Domain | Scope | Bugs | Checks (violated / holds) |
| --- | --- | --- | --- |
| [network](network/FINDINGS.md) | provider retry, streaming, stream display | N1–N2 | 4 / 3 + conformance |
| [agent-loop](agent-loop/FINDINGS.md) | step loop, tool pairing, cancel, `:tool-choice :none`, steering | L1–L5 | 11 / 8 |
| [tools](tools/FINDINGS.md) | tool execution, subprocesses, file writes, policy | K1–K9 | 10 / 5 |
| [context](context/FINDINGS.md) | prompt-prefix caching, usage and token accounting | C1–C7 | 7 / 3 |
| [sessions](sessions/FINDINGS.md) | persistence, crash/resume, compaction, locking, doctor | S1–S6 | 12 / 6 |
| [extensions](extensions/FINDINGS.md) | registry, event bus, `/reload` | X1–X5 | 9 / 2 |
| [scheduler](scheduler/FINDINGS.md) | presenter loop, cooperative tasks, Ctrl-C arm | D1–D3 | 4 / 7 |
| [tui-turns](tui-turns/FINDINGS.md) | tabs, side chat, Ctrl-C ownership, steering routing | T1–T4 | 6 / 5 |
| [presenters](presenters/FINDINGS.md) | print, JSON, stdio, web, rpc outcome, goal, `session send` | P1–P5 | 8 / 9 |
| [wire](wire/FINDINGS.md) | parent/child protocol, acks, result, parent mirror | W1–W4 | 6 / 7 + conformance |
| [subagents](subagents/FINDINGS.md) | run lifecycle, budgets, delivery, inheritance | R1–R6 | 8 / 3 |
| [auth](auth/FINDINGS.md) | OAuth refresh rotation, credential store, quota cache | A1–A5, Q1 | 6 / 4 |
| [serve](serve/FINDINGS.md) | design-first: attachable fen (#394, #396, #397), async UI contract (#398) | V1–V9 (V3 is in today's code; the rest are in the issue designs) | 14 / 9 (`proposed` protocol holds) |

Totals: 62 bugs in today's code (61 across the twelve code domains after counting P4 once, plus serve's V3) and 8 bugs in the serve designs, from 178 checks.

Every bug listed was confirmed against the real code (a throwaway probe or a line trace, recorded in its `FINDINGS.md`); model-only suspicions sit under each domain's "Open questions".
Related findings: P4 is C3 found independently (counted once); C6 is the prompt-cache cost of X3; P5 follows from L4; S1 is L1's persistence twin; P1 is N1 in the web presenter.

## The small core

The domains were modelled independently, and their "Core" sections converge on six rules.
Almost every bug above is one of them broken at one of several places that each re-implement it.

1. **Record the owner when work starts; never look it up later.**
   A turn, stream row, credential record, run, or extension contribution set is reached through the identity captured at its start, not through a global read at the moment of use.
   Broken by: T1–T4 (Ctrl-C, quit arm, steering, and `/btw` resolve "the current turn" globally), D2 (the cancel arm outlives its turn), N2 (a dead turn's open row is reused), W2 (`finalize` targets whatever the lagging mirror says), R3–R4 (completions delivered through the user's queue), A2 (a refresh writes over a newer login), X3 (name ownership falls out of edit order).
2. **Close everything exactly once, at one boundary.**
   Turns, streams, tool calls, runs, and processes each end through one exit that pairs what is open and emits one terminal outcome.
   Broken by: L1–L2 (tool calls left unpaired on exits nobody listed), S1 (the same after a crash), L4–L5, P2–P3, P5 (four classifiers disagree on how a turn ended), N1–N2, P1 (streams never closed or closed per presenter), W1, W4, R2 (runs and spill files left open at exit), K1, K6, K9 (processes and edits outliving cancel).
3. **One writer per durable resource, committing atomically.**
   A kernel-released lock held by every writer, and compare-then-rename with no yield between check and commit.
   Broken by: A1–A3, A5, Q1 (credential and quota writers race), S2–S4, S6 (session appends, cursor, and lock), K4–K5, K7 (tool writes torn, unchecked, or lost).
4. **Derive every view from one ledger.**
   Usage, context size, and outcomes are folds over one append-only record, not re-derived from whatever slice of `agent.messages` a consumer holds.
   Broken by: C1–C5, P4.
5. **One task table, one guarded step.**
   Every coroutine (turns, side chat, subagent pumps, decide tasks, refreshes) lives in one table resumed by one fault-isolated driver that also decides the poll cadence.
   Broken by: D1, D3, and the five ad hoc registries the scheduler domain lists.
6. **Policy is derived from the parent, not copied flag by flag.**
   Children, side chats, and reloaded extensions get their authority and settings from one record, validated uniformly.
   Broken by: R1 (a status label passed as `--thinking`), R6 (read-only by prompt text only), A4 (credentials pinned at startup), X5 (tools registered without validation).

Taken together, the core fen needs is roughly eight primitives:
a task table with a guarded step; a turn record closed by one `close-turn` that yields an `Outcome`; an event stream with explicit attempt and stream-close boundaries that presenters fold; a usage ledger; a durable-store primitive (kernel lock plus compare-and-rename) shared by sessions, auth, and file tools; a process job that kills its whole group; an extension contribution map swapped atomically when idle; and a subagent run table with a per-run mailbox, built from the previous three.
Each domain's `FINDINGS.md` lists the code its primitive would delete.
