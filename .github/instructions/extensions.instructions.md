---
applyTo: "extensions/**"
---

# First-party extensions

General rules for everything under `extensions/`.
Provider, TUI, and built-in-tool subtrees have additional scoped instructions
that layer on top of these.

- **Manifests must declare reload.**
  Extension modules that should hot-reload list themselves in their manifest's
  `reload-modules`; a new stateful module that isn't listed will silently go stale.
- **Don't copy-paste helpers.**
  A text/path/util helper used by two or more extensions moves to `fen.util.*`
  rather than being duplicated (#174, #105); flag fresh copies.
- **Prefer the events bus** over inventing a new hook or queue for cross-extension
  coordination (#196).

## Stateful workflows

For companions that schedule, stop, or resume work:

- enumerate statuses and verify each allowed transition;
- cover terminal, resumable, interrupted, and cap-reached states;
- correlate completion events with the active turn and reject stale or duplicate completion;
- persist stop/terminal transitions before asynchronous cancellation or shutdown;
- never automatically revive stopped or completed work after reload or restart;
- validate every persisted field that can affect branching or control flow.
