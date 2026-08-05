;; Default backend selector for fen.core.storage.
;;
;; This file is the swap point for the config-storage seam. The public module
;; (fen.core.storage) resolves (require :fen.core.storage.backend) and
;; dispatches read/write! through whatever this module exports. Tests pre-load
;; `package.loaded["fen.core.storage.backend"]` with a stub before requiring
;; the public module (see fen.testing.stub-storage!); an embedded host that
;; backs config with its own persistence ships a different backend module and
;; either replaces this file or pre-populates package.loaded from the launcher.
;;
;; Mirrors fen.util.path.backend / fen.core.extensions.loader.discover.backend:
;; one mechanism, the injectable backend, with the current XDG-file behavior
;; (io.open read, mkdir -p + temp-file + rename atomic write) kept as the
;; default.

(require :fen.core.storage.backends.default)
