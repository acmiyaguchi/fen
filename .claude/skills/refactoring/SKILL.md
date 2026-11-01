---
name: refactoring
description: Model-driven architectural refactoring and core parsimony cleanup — find seams in Quint models/issues, present a Before/After ASCII architecture diagram for user approval, delegate scoped implementation to a fast worker subagent (such as flash or implementer), and verify code + formal specs in lockstep. Use when simplifying architecture, cleaning up seams, removing duplicated boundary logic, or applying formal-modeling findings.
user-invocable: true
---

# Model-Driven Refactoring

Simplify architecture by collapsing duplicated seams into single boundary mechanisms, keeping the Fennel code and Quint formal models (`spec/`) in lockstep.
Use this when refactoring core/extension seams, applying `spec/*/FINDINGS.md` ("Smaller design" / "Would delete"), or running a core-parsimony pass (`docs/architecture.md#design-principles`); for local post-diff polish on already-written changes, use `/simplify` instead.

## Workflow

1. **Audit seams & formal models** — inspect the code, issues, and `spec/`.
2. **Present Before/After ASCII diagram (gate)** — show the structural collapse and wait for user approval before editing.
3. **Delegate implementation to a fast subagent** — hand the concrete file/line plan to `flash` (Antigravity) or `implementer` (`fen`).
4. **Verify code & formal specs in lockstep** — run Fennel checks, unit/conformance tests, Quint checks/mutants, and graph regeneration.
5. **Commit atomically** — keep refactoring, model updates, and skill/doc changes in clean, focused commits.

## 1. Audit seams & formal models

Read `docs/architecture.md#design-principles` and `spec/README.md`, then check:

- `spec/<domain>/FINDINGS.md` ("Smaller design" and "Would delete" sections) and `spec/core/<primitive>/`.
- `gh issue list --search "milestone:modeling"` or open parsimony issues (e.g. `#503`).
- Duplicated boundary logic across modules:
  - Per-exit cleanup vs. a single `xpcall` / `close-turn!` boundary.
  - Consumers re-deriving state or status by sniffing messages instead of reading one canonical `Outcome` or lifecycle event.
  - Multiple modules carrying private copies of the same helper or state transition.

Identify both what **changes** and what **gets deleted**.

## 2. Present Before/After ASCII diagram (Approval Gate)

Before making or delegating code edits, present a concise proposal to the user:

1. **Before vs. After ASCII diagram** showing the data/control-flow collapse and which duplicated paths disappear.
2. **What gets deleted / simplified** — exact functions, branches, and files.
3. **Formal model impact** — which `spec/<domain>/model.qnt`, `proofs/`, `witnesses.qnt`, `mutants.tsv`, `conform.sh`, and `FINDINGS.md` files will be updated.

Stop and wait for user confirmation on the diagram before implementing.

## 3. Delegate implementation to a fast subagent

Once the user approves the design, do not burn orchestrator context on mechanical edits.
Prepare a self-contained implementation prompt with:

- Exact file paths, function names, and line ranges for each seam.
- Edge cases discovered during audit (e.g., stubbed tests in `package.loaded`, FIFO ordering invariants in `spec/core/turn/turn.qnt`, mutant survival in `mutants.tsv`, or negative conformance in `conform.sh --negative`).
- The exact Quint model, proof, witness, and `FINDINGS.md` updates required.
- The validation commands to run before reporting back.

### Drivers

- **Antigravity (`invoke_subagent`):** invoke `TypeName: "self"` with `Model: "flash"` and a descriptive `Role`.
- **fen (`subagent` tool):** invoke the `implementer` agent in `.fen/agents/implementer.md` on a fast worker model with an explicit `cwd` and bounded tool/time budgets.

While the subagent works, the parent waits for completion rather than polling.

## 4. Verify code & formal specs in lockstep

A refactoring that touches a modeled boundary is not done until both code and `spec/` pass:

```sh
fennel scripts/test/fennel-check.fnl
make test
make check-spec SPECS="spec/<domain> spec/core/<primitive>"
SPEC_MUTANTS=1 sh scripts/spec/check.sh spec/<domain>
```

When proof models (`verify.tsv`) or module imports change, also run:

```sh
make verify-spec SPECS="spec/<domain>/proofs/<proof>"
make graphs
make fmt
make check
```

Checklist before committing:

- Did `conform.sh` and `conform.sh --negative` both pass?
- Do all mutants in `mutants.tsv` still get caught (`SPEC_MUTANTS=1`)?
- Were `FINDINGS.md` "Would delete" / status notes updated to match the code?
- Were `docs/graphs/*.dot` regenerated if any `require` edge changed?
- Are hot-reload invariants (`AGENTS.md`) and one-sentence-per-line Markdown preserved?
