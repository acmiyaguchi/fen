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

## Conventions

- Model the code as it is, cite the files it mirrors, and keep models small: 2–3 turns, attempts, or tabs are enough to expose interleavings.
- A bug counts when the model finds it **and** it is confirmed against the real code (a throwaway Busted probe, a REPL run, or a line-by-line trace through the source).
  Model-only suspicions go under "Open questions" in `FINDINGS.md`.
- Invariants are named for the property (`noOpenRowWhenIdle`), not the bug.
- Quint 0.33 gotchas: parameterised actions need a return type (`action a(x: int): bool = ...`); strings do not concatenate; ITF trace keys are namespaced (`<main>::<module>::<var>`).
- Shortest counterexample: rerun `quint run --main=M --invariant=I --max-steps=N --out-itf=t.json model.qnt` with increasing `N`.

## Domains

| Domain | Scope | Bugs |
| --- | --- | --- |
| [network](network/FINDINGS.md) | provider retry, streaming, stream display | 2 |
