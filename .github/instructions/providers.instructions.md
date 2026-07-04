---
applyTo: "extensions/adapters/providers/**"
---

# Streaming providers

Providers wrap different wire formats behind one interface.
The recurring risk here is duplicating the transport spine per provider.

- **Build on the shared skeleton.**
  New streaming providers use the shared streaming-provider skeleton
  (`extensions/adapters/providers/shared`); do not add another copy of the
  transport/SSE loop (#189).
- **Isolate only the real differences.**
  Auth headers, request shaping, and wire/event parsing are what varies per provider;
  keep everything else in the shared layer.
- **Watch stream accumulation cost.**
  Avoid quadratic string/table accumulation across deltas and per-delta work that is
  thrown away (e.g. a JSON parse whose result is unused) (#192).
- **HTTP goes through `fen.util.http.request`** and `fen_http.so` — never `lua-curl`.
