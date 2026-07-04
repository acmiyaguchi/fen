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
- **Registration is idempotent.**
  Commands/tools/fragments/events registered by an extension must clear prior owner
  registrations or rely on the loader's owner cleanup.
- **Don't copy-paste helpers.**
  A text/path/util helper used by two or more extensions moves to `fen.util.*`
  rather than being duplicated (#174, #105); flag fresh copies.
- **Prefer the events bus** over inventing a new hook or queue for cross-extension
  coordination (#196).
- **State vs behavior stays split** for reload: persistent tables in a non-reloadable
  companion, logic/rendering in reloadable siblings.
