;; Default backend selector for fen.util.clock.
;;
;; This file is the swap point for the clock seam. The public API
;; (fen.util.clock) resolves (require :fen.util.clock.backend) and dispatches
;; monotonic-ms/sleep-ms through whatever this module exports. Tests pre-load
;; `package.loaded["fen.util.clock.backend"]` with a stub before requiring the
;; public module (see fen.testing.stub-clock!); a host without the fen_process
;; native module (WASM, an event-loop runtime with its own timers) ships a
;; different backend module and either replaces this file or pre-populates
;; package.loaded from the launcher.
;;
;; Mirrors fen.util.http.backend / fen.util.path.backend: one mechanism, the
;; injectable backend, with the current fen_process-backed behavior kept as the
;; default.

(require :fen.util.clock.backends.native)
