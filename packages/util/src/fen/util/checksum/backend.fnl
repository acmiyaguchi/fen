;; Default backend selector for fen.util.checksum.
;;
;; This file is the swap point for the fingerprint-provider seam. The public
;; API (fen.util.checksum) resolves (require :fen.util.checksum.backend) and
;; dispatches file/module fingerprinting through whatever this module exports.
;; Tests pre-load `package.loaded["fen.util.checksum.backend"]` with a stub
;; before requiring the public module (see fen.testing.stub-checksum!); a host
;; whose modules load through a custom package.searchers entry (a WASM/in-VM
;; compiler) ships a different backend module that supplies a version/etag per
;; module and either replaces this file or pre-populates package.loaded from
;; the launcher.
;;
;; Mirrors fen.util.path.backend / fen.util.clock.backend: one mechanism, the
;; injectable backend, with the current io.open/searchpath behavior kept as the
;; default.

(require :fen.util.checksum.backends.default)
