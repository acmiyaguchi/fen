;; Default backend selector for fen.util.process.
;;
;; This file is the swap point for the subprocess seam. The public API
;; (fen.util.process) resolves (require :fen.util.process.backend) and
;; dispatches its subprocess primitives through whatever this module exports.
;; Tests pre-load `package.loaded["fen.util.process.backend"]` with a stub
;; before requiring the public module (see fen.testing.stub-process!); a host
;; without a POSIX subprocess surface (WASM, a sandboxed runtime) ships a
;; different backend module and either replaces this file or pre-populates
;; package.loaded from the launcher.
;;
;; Mirrors fen.util.http.backend / fen.util.path.backend: one mechanism, the
;; injectable backend, with the current fen_process-backed behavior kept as the
;; default.

(require :fen.util.process.backends.posix)
