---
applyTo: "packages/*/src/**/*.fnl,extensions/**/*.fnl"
---

# Runtime Fennel — hot-reload discipline

`/reload` is the primary development loop, so runtime `.fnl` modules must stay reloadable.
The mechanism differs by location (core auto-reloads; extensions list `reload-modules`
in their manifest), but these principles apply across source packages and extensions.

- **Split persistent state from behavior.**
  Long-lived state tables belong in a small non-reloadable companion module;
  rendering and logic belong in reloadable siblings.
- **Resolve cross-module behavior at call time.**
  Prefer `module.fn` lookups over function locals captured in long-lived state,
  so a reload actually swaps in the new implementation.
- **Keep long work cooperative.**
  Network calls, subprocess/file drains, bulk reload/discovery, and large scans
  should accept and pass a yield callback and yield between chunks,
  so the TUI can repaint and process cancel/quit keys.
  A yield parameter alone is insufficient: trace a production caller and verify
  that it passes the callback from a cooperative runtime path rather than only in tests.
- **Make registration side effects idempotent.**
  Anything that registers commands/tools/fragments/events must clear prior owner
  registrations or rely on the loader's owner cleanup, so re-running is safe.
