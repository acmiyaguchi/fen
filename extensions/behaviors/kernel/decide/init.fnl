;; Decide extension entry point.
;;
;; Opt-in (`:enabled-by-default false`). The decision service lives in
;; `fen.extensions.decide.service` so cross-extension consumers never capture
;; this entry module (the loader cache-busts entry modules on a fresh load!).

(local store (require :fen.extensions.decide.state))
(local service (require :fen.extensions.decide.service))

(local M {})

;; @doc fen.extensions.decide.register
;; kind: function
;; signature: (register api) -> true
;; summary: Capture the api handle for the decision service and pump pending ask-async! tasks on each :runtime-tick.
;; tags: decide register
(fn M.register [api]
  (set store.api api)
  ;; Resolved through the module table at call time so /reload stays safe.
  (api.on :runtime-tick (fn [_ev] (service.pump!)))
  true)

M
