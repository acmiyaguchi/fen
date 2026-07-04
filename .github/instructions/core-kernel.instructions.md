---
applyTo: "packages/core/**"
---

# Core microkernel — parsimony guardrails

`packages/core` is the microkernel under an active core-shrinking program
(`core-parsimony` milestone).
New code here must not widen the sprawl the milestone removes.

- **One mechanism per job.**
  Prefer the events bus and existing register kinds over new hook points, kinds, or queues.
  Adding a parallel dispatch path is the thing this milestone is undoing (#196, #171).
- **Keep policy and data out of the kernel.**
  Doc data and provider transport policy do not belong in `packages/core` (#195).
- **Kernel state is reloadable-aware.**
  Core/util `fen.*` modules reload automatically via `package.loaded`;
  keep persistent identity in the designated state modules
  (`fen.core.extensions.state`, and see the reload loader) rather than adding new
  stateful modules outside reload without a clear reason.
- **Prefer data-driven dispatch** over hand-maintained lists and bespoke branches;
  the register-kind consolidation (#196) is the direction of travel.
