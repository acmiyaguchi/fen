;; Default backend selector for fen.util.random.
;;
;; This file is the swap point for the CSPRNG seam. The public API
;; (fen.util.random) resolves (require :fen.util.random.backend) and dispatches
;; `bytes` through whatever this module exports. Tests pre-load
;; `package.loaded["fen.util.random.backend"]` with a stub before requiring the
;; public module (see fen.testing.stub-random!); a host without the fen_random
;; native module (WASM, a runtime with its own CSPRNG) ships a different backend
;; module and either replaces this file or pre-populates package.loaded from the
;; launcher.
;;
;; Mirrors fen.util.http.backend / fen.util.path.backend: one mechanism, the
;; injectable backend, with the current fen_random-backed behavior kept as the
;; default.

(require :fen.util.random.backends.native)
