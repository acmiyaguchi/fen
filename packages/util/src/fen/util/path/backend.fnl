;; Default backend selector for fen.util.path.
;;
;; This file is the swap point for the filesystem/env seam. The public API
;; (fen.util.path) resolves (require :fen.util.path.backend) and dispatches
;; its probes through whatever this module exports. Tests pre-load
;; `package.loaded["fen.util.path.backend"]` with a stub before requiring the
;; public module (see fen.testing.stub-path-vfs!); a host that runs fen without
;; a POSIX shell (WASM, a sandboxed VFS) ships a different backend module and
;; either replaces this file or pre-populates package.loaded from the launcher.
;;
;; Mirrors fen.util.http.backend: one mechanism, the injectable backend, with
;; the current lfs-preferred/popen-fallback POSIX behavior kept as the default.

(require :fen.util.path.backends.posix)
