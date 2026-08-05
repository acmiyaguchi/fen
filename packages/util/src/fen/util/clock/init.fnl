;; Monotonic clock and cooperative sleep, behind an injectable backend seam.
;;
;; These two primitives are on the agent.step hot path (fen.core.agent measures
;; per-call latency with monotonic-ms), so they live in their own tiny module
;; instead of fen.util.process. That keeps an embedded/headless turn free of any
;; subprocess dependency: requiring the clock never pulls in fen_process's
;; spawn/pipe surface.
;;
;; The public API resolves (require :fen.util.clock.backend) once at load and
;; dispatches through it. The default backend (fen.util.clock.backends.native)
;; wraps the fen_process native module's monotonic_ms/sleep_ms. Tests and hosts
;; swap the backend by pre-loading `package.loaded["fen.util.clock.backend"]`
;; before requiring this module (see fen.testing.stub-clock!). This mirrors the
;; fen.util.http and fen.util.path seams: one mechanism, current behavior as the
;; default. See docs/architecture.md.

;; Resolved once at load, mirroring fen.util.http / fen.util.path. On /reload
;; the module re-requires the backend, and tests swap it by pre-loading
;; package.loaded before requiring this module.
(local backend (require :fen.util.clock.backend))

(local M {})

;; @doc fen.util.clock.monotonic-ms
;; kind: function
;; signature: (monotonic-ms) -> number
;; summary: Return a monotonic clock reading in milliseconds via the injectable clock backend.
;; tags: util clock time monotonic
(fn M.monotonic-ms []
  (backend.monotonic-ms))

;; @doc fen.util.clock.sleep-ms
;; kind: function
;; signature: (sleep-ms ms) -> nil
;; summary: Sleep for the given number of milliseconds via the injectable clock backend.
;; tags: util clock time sleep
(fn M.sleep-ms [ms]
  (backend.sleep-ms ms))

M
