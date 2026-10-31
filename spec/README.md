# Design models

Executable [Quint](https://quint-lang.org) models of fen's core contracts.
Each model states what a subsystem is supposed to guarantee, checks the current design against it by simulation, and records the counterexamples it finds.
The goal is twofold: catch design bugs that live in interleavings (retries, cancels, reloads, two processes) rather than in any one function, and name the small core each subsystem actually needs.

These are design artifacts, not runtime code.
Quint is a dev-only dependency (in `nix develop`); nothing here ships in the binary.

## Running

```sh
nix develop          # provides quint and Apalache
make check-spec      # fast gate: simulation, witnesses, coverage, conformance
make check-spec-full # also mutants, every violated row simulated, 20000 samples
make check-spec SPECS=spec/network
make check-spec SPECS=spec/core/turn
make verify-spec     # Apalache proof obligations (verify.tsv); minutes
```

Neither is part of `make check` or CI.
`check-spec` is the fast gate: about a minute on a 30-core machine, CPU-bound, so slower on fewer cores. It simulates with quint's Rust backend (bundled with the nixpkgs quint, so nothing is downloaded), 10000 traces per `holds` group (2000 for `fix<issue>` instances and for proof models, whose `holds` rows `verify-spec` proves), and treats a `violated` row whose invariant a witness refutes as confirmed by that witness.
Run `check-spec-full` and `verify-spec` before merging a change to a model, a core primitive, or a proof model.

## Kinds of evidence

Every claim in a `FINDINGS.md` or README says which kind of evidence backs it:

| Kind | Meaning | Where it comes from |
| --- | --- | --- |
| counterexample | a concrete trace breaks the property | a `violated` row, and the issue's witness in `witnesses.qnt` |
| sampled | no counterexample in the simulated traces | a `holds` row in `check-spec` (20000 traces x 20 steps) |
| bounded-safe | no execution of up to N steps breaks it | a `bounded` obligation in `verify.tsv` |
| inductive | holds initially and every step preserves it: any depth | an `inductive` obligation in `verify.tsv` |
| refinement | every concrete step is a step (or stutter) of the abstract spec | a `refines...` invariant on a monitor (see `core/README.md`) |
| liveness | something eventually happens | none yet: no model states fairness assumptions, so no invariant may claim it |
| confirmed | the real code does it | a `known-bug` probe test, a conformance check, or a line trace in `FINDINGS.md` |

Invariant names must not claim more than their kind: a per-iteration bound is not "no starvation".

## Layout

`spec/core/` models the core primitives the domains converge on; see [`core/README.md`](core/README.md).
Each other directory is one domain. Its `model.qnt` is the *integration model*: it mirrors today's code, reproduces bugs, and feeds conformance, so it stays as detailed as the bugs need.
Small *proof models* for individual contracts live beside it in `spec/<domain>/proofs/<name>/`, with the same files, and are what `verify.tsv` obligations target.

| File | Purpose |
| --- | --- |
| `model.qnt` | The model. Pure step functions where the code has them; actions for the environment (network, user, clock, other process). |
| `checks.tsv` | `main<TAB>invariant<TAB>holds\|violated<TAB>issues`, run by `scripts/spec/check.sh`. `issues` names the GitHub issue(s) a `violated` row records. |
| `FINDINGS.md` | Scope, code it mirrors, input assumptions (what the environment actions can and cannot produce), bugs (counterexample + how it was confirmed against real code), candidate fixes, and the domain's minimal core. |
| `witnesses.qnt` | Module `witnesses`: deterministic `run` traces checked by `quint test`. `w<issue>...Test` reproduces that issue's counterexample, so a row cannot stay `violated` for a different bug; `reach...Test` shows a `fixed`/`proposed` instance still reaches its interesting cases (completion, cancel, repair, concurrency), so no invariant passes vacuously. `check-spec` fails if an issue has no witness. |
| `mutants.tsv` | `file<TAB>sed edit<TAB>main<TAB>invariant<TAB>description`: a deliberately broken model that the invariant must catch. |
| `verify.tsv` | `main<TAB>invariants<TAB>bounded\|inductive<TAB>steps<TAB>seconds<TAB>why`: Apalache obligations for `verify-spec`. `why` justifies the bound, e.g. the length of the known counterexample it must cover. |

A `violated` row records a known bug in the current design: the check passes while the model still finds a counterexample.
When the code is fixed, update the model, flip the row to `holds`, drop its issue column, and close the issue.
Candidate fixes are named: a model takes `const FIXES: Set[str]` and guards each fix with `FIXES.contains("<issue>")`.
The `fixed` instance enables every fix and must satisfy every invariant the fixes claim; a `violated` row on `fixed` records what even the fixed design does not provide, and names its issue (tools: an outside writer between the check and the rename, #657, and a crash between two renames, #656). A `fix<issue>` instance enables one fix, so a row can say which fix it needs and fixes can be checked one at a time.

Each confirmed bug also has a probe against the real code: a Busted test in the owning package or extension, `tests/issue_<n>_<slug>_test.fnl`, built on `fen.testing`'s `known-bug`.
It passes while the bug reproduces and fails once it stops, so the fix PR turns it into a regular test of the correct behaviour in the same change that flips the rows.

## Conformance

A model that is never compared with the code drifts into a second, stale description.
A domain may ship `conform.sh`, which `check-spec` runs alongside the domain's checks, together with `conform.sh --negative`, which compares against a deliberately wrong model and must fail:

| Domain | Kind | What it compares |
| --- | --- | --- |
| [wire](wire/conform.qnt) | table | Every (state, control) and (state, event) pair of the model's `decide`/`advance` against `fen.util.wire_session` (`scripts/spec/conform-wire.fnl`). |
| [wire](wire/lifecycle_test.fnl) | lifecycle replay | 300 model traces through the real rpc child (wire_session, cooperative loop, mock provider): every lifecycle event in order (acks, drop notices, result, exit) and spill files. Also fails when the code's tables have a state, control, or event the model lacks. |
| [network](network/replay_test.fnl) | trace replay | 300 Quint traces of the `current` model, each event sequence fed through the real TUI ingest; the transcript must equal the model's. |
| [network](network/producer_test.fnl) | producer replay | The same traces as scripted HTTP under the real turn_submit, agent, provider, and retry chain: the emitted events must equal the model's, and the TUI rows, open-row count, hosted and retrying flags must match after every model step. |

Conformance pins the model to today's code, bugs included.
A fix therefore changes both sides in one PR: e.g. the network streaming-row fix flips `SPEC_NETWORK_MAIN` in `network/conform.sh` to `fixed` (today 113 of 200 `fixed` traces diverge from the code, as they should).

## Conventions

- Model the code as it is, cite the files it mirrors, and keep models small: 2–3 turns, attempts, or tabs are enough to expose interleavings.
- A bug counts when the model finds it **and** it is confirmed against the real code (a throwaway Busted probe, a REPL run, or a line-by-line trace through the source).
  Model-only suspicions go under "Open questions" in `FINDINGS.md`.
- Invariants are named for the property (`noOpenRowWhenIdle`), not the bug.
- A domain's `fixed` instance uses a core primitive by importing its pure module (`import turn.* from "../core/turn/turn"`) and projecting its own types onto the primitive's, not by copying the rule.
- Models must run on the quint in `nix develop` (0.32 today). Keep them parseable by 0.25 too: `from` is a keyword there, so don't use it as a field name.
- Models that have `verify.tsv` obligations must be Apalache-friendly: no `range(a, b)` with non-constant bounds (fold with an index counter instead), bounded lists, and invariants that do not rebuild whole histories at every step.
- Quint gotchas:
  - parameterised actions need a return type (`action a(x: int): bool = ...`); strings do not concatenate; ITF trace keys are namespaced (`<main>::<module>::<var>`);
  - `x' = a or b` parses as `(x' = a) or b` (same for `and`): the right-hand side silently becomes a guard. Write `x' = (a or b)`;
  - `set`, `next` and other built-in names cannot be redefined;
  - `quint test` mixes up two instances of one parameterised module that share an inner import alias: give monitor modules distinct aliases;
  - `quint verify` crashes flattening an aliased import (`import m as A`) inside a parameterised module: import it unqualified there;
  - for `quint verify`, a reachable state with no enabled action is a counterexample (add a stutter action), an inductive invariant must start with `x.in(<finite set>)` for every variable, and a file import puts every module in one namespace (`current`/`fixed` from two files clash).
- Shortest counterexample: rerun `quint run --main=M --invariant=I --max-steps=N --out-itf=t.json model.qnt` with increasing `N`.

## Domains

Every bug in today's code is a GitHub issue in the [`modeling` milestone](https://github.com/acmiyaguchi/fen/milestone/11), and every `violated` row in a `checks.tsv` names its issue in the fourth column.
The serve design findings (V1–V9) are posted as comments on the design issues they affect; the one that is also in today's code is #638.

| Domain | Scope | Bugs | Integration checks (violated / holds) | Proof models (`proofs/`) |
| --- | --- | --- | --- | --- |
| [network](network/FINDINGS.md) | provider retry, streaming, stream display | #629, #630 | 5 / 6 + producer and ingest conformance | stream-rows |
| [agent-loop](agent-loop/FINDINGS.md) | step loop, tool pairing, cancel, `:tool-choice :none`, steering | #606, #607, #608, #609, #610 | 13 / 16, refinement monitors | loop (refinement, 12 steps) |
| [tools](tools/FINDINGS.md) | tool execution, subprocesses, file writes, policy | #651–#659 | 15 / 16 | process-group, output-envelope, utf8-tail, file-commit, multi-file-commit, edit-unique, popen-cancel, dispatch |
| [context](context/FINDINGS.md) | prompt-prefix caching, usage and token accounting | #617–#623 | 7 / 10 | prefix, ledger |
| [sessions](sessions/FINDINGS.md) | persistence, crash/resume, compaction, locking, doctor | #639–#644 | 14 / 16 | lock, persistence, replay |
| [extensions](extensions/FINDINGS.md) | registry, event bus, `/reload` | #624–#628 | 9 / 11 | contrib, fingerprint, turn-identity, validation |
| [scheduler](scheduler/FINDINGS.md) | presenter loop, cooperative tasks, Ctrl-C arm | #635–#637 | 4 / 11 | cancel-arm, pump |
| [tui-turns](tui-turns/FINDINGS.md) | tabs, side chat, Ctrl-C ownership, steering routing | #660–#663 | 6 / 12 | ctrl-c, side-ownership, steering, drafts |
| [presenters](presenters/FINDINGS.md) | print, JSON, stdio, web, rpc outcome, goal, `session send` | #631–#634 (and #619, shared with context) | 9 / 16 | outcome, web-rows |
| [wire](wire/FINDINGS.md) | parent/child protocol, acks, result, parent mirror | #664–#667 | 6 / 13 + table and lifecycle conformance | acks |
| [subagents](subagents/FINDINGS.md) | run lifecycle, budgets, delivery, inheritance | #645–#650 | 8 / 11 | inheritance, lifecycle |
| [auth](auth/FINDINGS.md) | OAuth refresh rotation, credential store, quota cache | #611–#616 | 7 / 11 | rotation, pinning, quota |
| [serve](serve/FINDINGS.md) | design-first: attachable fen (#394, #396, #397), async UI contract (#398) | #638, plus V1–V9 on #396, #397, #398 | 15 / 8 (`proposed` protocol holds) | controls, requests, replay |

Totals: 62 bugs in today's code (#606–#667) and 8 bugs in the serve designs. Every bug has a witness and a `known-bug` probe against the real code (the serve design findings, which have no code, have witnesses only). The whole tree is 51 models with about 640 `check-spec` checks (about 780 in `check-spec-full`) and 68 `verify-spec` obligations, most of them inductive.

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
   A kernel-released lock held by every fen writer, write-to-temp then rename with no yield between check and commit, and a re-check just before the rename. That serializes fen's own writers and is cancel-atomic; it is not a compare-and-swap against writers outside fen, nor crash-atomic across several files (spec/tools).
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

The primitives are modelled under [`core/`](core/README.md) as they are designed, starting with close-turn (#668): an abstract spec proved inductively, replay laws proved over every short log, and agent-loop models that are checked to refine the spec step by step.
