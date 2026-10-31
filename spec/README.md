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
make check-spec SPECS=spec/core/turn
```

`check-spec` is not part of `make check`.

## Layout

`spec/core/` models the core primitives the domains converge on; see [`core/README.md`](core/README.md).
Each other directory is one domain:

| File | Purpose |
| --- | --- |
| `model.qnt` | The model. Pure step functions where the code has them; actions for the environment (network, user, clock, other process). |
| `checks.tsv` | `main<TAB>invariant<TAB>holds\|violated<TAB>issues`, run by `scripts/spec/check.sh`. `issues` names the GitHub issue(s) a `violated` row records. |
| `FINDINGS.md` | Scope, code it mirrors, bugs (counterexample + how it was confirmed against real code), candidate fixes, and the domain's minimal core. |

A `violated` row records a known bug in the current design: the check passes while the model still finds a counterexample.
When the code is fixed, update the model, flip the row to `holds`, drop its issue column, and close the issue.
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
- A domain's `fixed` instance uses a core primitive by importing its pure module (`import turn.* from "../core/turn/turn"`) and projecting its own types onto the primitive's, not by copying the rule.
- Models must run on the quint in `nix develop` (0.25.x today) as well as current releases: `from` is a keyword there, so don't use it as a field name.
- Quint gotchas: parameterised actions need a return type (`action a(x: int): bool = ...`); strings do not concatenate; ITF trace keys are namespaced (`<main>::<module>::<var>`).
- Shortest counterexample: rerun `quint run --main=M --invariant=I --max-steps=N --out-itf=t.json model.qnt` with increasing `N`.

## Domains

Every bug in today's code is a GitHub issue in the [`modeling` milestone](https://github.com/acmiyaguchi/fen/milestone/11), and every `violated` row in a `checks.tsv` names its issue in the fourth column.
The serve design findings (V1–V9) are posted as comments on the design issues they affect; the one that is also in today's code is #638.

| Domain | Scope | Bugs | Checks (violated / holds) |
| --- | --- | --- | --- |
| [network](network/FINDINGS.md) | provider retry, streaming, stream display | #629, #630 | 4 / 3 + conformance |
| [agent-loop](agent-loop/FINDINGS.md) | step loop, tool pairing, cancel, `:tool-choice :none`, steering | #606, #607, #608, #609, #610 | 11 / 8 |
| [tools](tools/FINDINGS.md) | tool execution, subprocesses, file writes, policy | #651, #652, #653, #654, #655, #656, #657, #658, #659 | 10 / 5 |
| [context](context/FINDINGS.md) | prompt-prefix caching, usage and token accounting | #617, #618, #619, #620, #621, #622, #623 | 7 / 3 |
| [sessions](sessions/FINDINGS.md) | persistence, crash/resume, compaction, locking, doctor | #639, #640, #641, #642, #643, #644 | 12 / 6 |
| [extensions](extensions/FINDINGS.md) | registry, event bus, `/reload` | #624, #625, #626, #627, #628 | 9 / 2 |
| [scheduler](scheduler/FINDINGS.md) | presenter loop, cooperative tasks, Ctrl-C arm | #635, #636, #637 | 4 / 7 |
| [tui-turns](tui-turns/FINDINGS.md) | tabs, side chat, Ctrl-C ownership, steering routing | #660, #661, #662, #663 | 6 / 5 |
| [presenters](presenters/FINDINGS.md) | print, JSON, stdio, web, rpc outcome, goal, `session send` | #631, #632, #633, #634 (and #619, shared with context) | 8 / 9 |
| [wire](wire/FINDINGS.md) | parent/child protocol, acks, result, parent mirror | #664, #665, #666, #667 | 6 / 7 + conformance |
| [subagents](subagents/FINDINGS.md) | run lifecycle, budgets, delivery, inheritance | #645, #646, #647, #648, #649, #650 | 8 / 3 |
| [auth](auth/FINDINGS.md) | OAuth refresh rotation, credential store, quota cache | #611, #612, #613, #614, #615, #616 | 6 / 4 |
| [serve](serve/FINDINGS.md) | design-first: attachable fen (#394, #396, #397), async UI contract (#398) | #638, plus V1–V9 on #396, #397, #398 | 14 / 9 (`proposed` protocol holds) |

Totals: 62 bugs in today's code (#606–#667) and 8 bugs in the serve designs, from 178 checks.

Every bug listed was confirmed against the real code (a throwaway probe or a line trace, recorded in its `FINDINGS.md`); model-only suspicions sit under each domain's "Open questions".
Related findings: the presenters model found #619 independently; #622 is the prompt-cache cost of #626; #634 follows from #609; #639 is #606's persistence twin; #631 is #629 in the web presenter.

## The small core

The domains were modelled independently, and their "Core" sections converge on six rules.
Almost every bug above is one of them broken at one of several places that each re-implement it.

1. **Record the owner when work starts; never look it up later.**
   A turn, stream row, credential record, run, or extension contribution set is reached through the identity captured at its start, not through a global read at the moment of use.
   Broken by: #660, #661, #662, #663 (Ctrl-C, quit arm, steering, and `/btw` resolve "the current turn" globally), #636 (the cancel arm outlives its turn), #630 (a dead turn's open row is reused), #665 (`finalize` targets whatever the lagging mirror says), #647, #648 (completions delivered through the user's queue), #612 (a refresh writes over a newer login), #626 (name ownership falls out of edit order).
2. **Close everything exactly once, at one boundary.**
   Turns, streams, tool calls, runs, and processes each end through one exit that pairs what is open and emits one terminal outcome.
   Broken by: #606, #607 (tool calls left unpaired on exits nobody listed), #639 (the same after a crash), #609, #610, #632, #633, #634 (four classifiers disagree on how a turn ended), #629, #630, #631 (streams never closed or closed per presenter), #664, #667, #646 (runs and spill files left open at exit), #651, #656, #659 (processes and edits outliving cancel).
3. **One writer per durable resource, committing atomically.**
   A kernel-released lock held by every writer, and compare-then-rename with no yield between check and commit.
   Broken by: #611, #612, #613, #615, #616 (credential and quota writers race), #640, #641, #642, #644 (session appends, cursor, and lock), #654, #655, #657 (tool writes torn, unchecked, or lost).
4. **Derive every view from one ledger.**
   Usage, context size, and outcomes are folds over one append-only record, not re-derived from whatever slice of `agent.messages` a consumer holds.
   Broken by: #617, #618, #619, #620, #621.
5. **One task table, one guarded step.**
   Every coroutine (turns, side chat, subagent pumps, decide tasks, refreshes) lives in one table resumed by one fault-isolated driver that also decides the poll cadence.
   Broken by: #635, #637, and the five ad hoc registries the scheduler domain lists.
6. **Policy is derived from the parent, not copied flag by flag.**
   Children, side chats, and reloaded extensions get their authority and settings from one record, validated uniformly.
   Broken by: #645 (a status label passed as `--thinking`), #650 (read-only by prompt text only), #614 (credentials pinned at startup), #628 (tools registered without validation).

Taken together, the core fen needs is roughly eight primitives, each tracked by a `core:` issue in the milestone (#668–#675):
a task table with a guarded step; a turn record closed by one `close-turn` that yields an `Outcome`; an event stream with explicit attempt and stream-close boundaries that presenters fold; a usage ledger; a durable-store primitive (kernel lock plus compare-and-rename) shared by sessions, auth, and file tools; a process job that kills its whole group; an extension contribution map swapped atomically when idle; and a subagent run table with a per-run mailbox, built from the previous three.
Each domain's `FINDINGS.md` lists the code its primitive would delete.

The primitives are modelled under [`core/`](core/README.md) as they are designed, starting with close-turn (#668), which the agent-loop and sessions `fixed` instances already share.
