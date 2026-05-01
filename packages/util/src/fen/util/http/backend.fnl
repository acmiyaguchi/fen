;; Default backend selector for fen.util.http.
;;
;; This file is the swap point. The public API resolves
;; (require :fen.util.http.backend) and dispatches through whatever this
;; module exports. Tests pre-load `package.loaded["fen.util.http.backend"]`
;; with a stub before requiring providers; future builds (WASM,
;; single-file with a different transport) ship a different backend
;; module and either replace this file or pre-populate package.loaded
;; from the launcher.

(require :fen.util.http.backends.native)
