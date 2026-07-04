---
applyTo: "extensions/adapters/presenters/tui/**"
---

# TUI presenter

The TUI targets slow ARMv7 hardware, so the paint path is performance-sensitive.

- **termbox2 only.**
  Rendering uses termbox2; flag any reintroduction of `lcurses`.
- **Keep the paint path cheap.**
  Avoid per-frame deep copies / freezes and cache-key churn on the paint path;
  work that runs every frame should be O(visible), not O(history) (#193).
- **Stay cooperative.**
  Long renders, scans, and drains should yield so input (cancel/quit) stays responsive.
- **Split reload state from render logic.**
  Persistent view/scroll state lives in the non-reloadable state module
  (`fen.extensions.tui.state`); rendering lives in reloadable siblings.
