;; Default backend selector for extension discovery.
;;
;; This file is the swap point for the manifest-enumeration seam. The public
;; discover module (fen.core.extensions.loader.discover) resolves
;; (require :fen.core.extensions.loader.discover.backend) and dispatches its
;; single `enumerate` entry point through whatever this module exports; the
;; public module then applies the shared dedupe/version annotations. Tests
;; pre-load `package.loaded["fen.core.extensions.loader.discover.backend"]`
;; with a stub before requiring the public module (see
;; fen.testing.stub-discover-enumeration!); an embedded host with no `find`, no
;; cwd ancestry, and no filesystem ships a different backend module that
;; supplies the discovered-manifest list directly, either replacing this file
;; or pre-populating package.loaded from the launcher.
;;
;; Mirrors fen.util.path.backend / fen.util.process.backend: one mechanism, the
;; injectable backend, with the current POSIX enumeration kept as the default.

(require :fen.core.extensions.loader.discover.backends.posix)
