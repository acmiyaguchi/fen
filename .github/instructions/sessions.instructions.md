---
applyTo: "extensions/adapters/session-backends/**,packages/fen/src/fen/session_lifecycle.fnl,packages/fen/tests/session_lifecycle_test.fnl,packages/core/src/fen/core/extensions/register/session_backend.fnl"
---

# Sessions and durable extension state

Session files are append-only durable data and must remain recoverable and forward-compatible.

- **Validate symmetrically.** Anything accepted by an append API must be readable by the corresponding restore path.
- **Separate structural and semantic validity.** Backend validation owns the generic entry shape; extension-specific versions and state invariants stay with the owning extension.
- **Fall back safely.** When selecting latest state, skip rejected entries and continue to an older acceptable entry rather than letting one malformed record hide valid history.
- **Recover partial history.** Torn lines, malformed entries, and unknown entry types must not prevent recovery of preceding valid entries.
- **Do not restore process identity.** File handles, coroutine identities, active turn IDs, and similar runtime-only values must not become valid identities after restart.
- **Preserve isolation.** Check `/new`, `/continue`, handoff, reload, and session switching for owner- or session-state leakage.
- **Exercise real cooperation.** Large reads must receive a yield callback from the production lifecycle path; an optional argument used only by tests is not sufficient.
- **Keep caches coherent.** Append and session switching must invalidate or replace cached metadata without changing latest-entry selection.
