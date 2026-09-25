---
applyTo: "packages/core/**"
---

# Core microkernel — parsimony guardrails

`packages/core` is the microkernel.
The `core-parsimony` milestone shrank it; new code here must not regrow that sprawl.

- **One mechanism per job.**
  Prefer the events bus and existing register kinds over new hook points, kinds, or queues.
  Adding a parallel dispatch path is the thing that milestone undid (#196, #171).
- **Keep policy and data out of the kernel.**
  Doc data and provider transport policy do not belong in `packages/core` (#195).
- **Kernel state is reloadable-aware.**
  Core/util `fen.*` modules reload automatically via `package.loaded`;
  keep persistent identity in the designated state modules
  (`fen.core.extensions.state`, and see the reload loader) rather than adding new
  stateful modules outside reload without a clear reason.
- **Prefer data-driven dispatch** over hand-maintained lists and bespoke branches;
  follow the register-kind consolidation (#196).
