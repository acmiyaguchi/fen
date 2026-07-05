;; Steering extension entry point.
;;
;; The queue service API lives in `fen.extensions.steering.service` so that
;; cross-extension consumers never capture this entry module (the loader
;; cache-busts entry modules on a fresh load!).

(local service (require :fen.extensions.steering.service))

(local M {})

;; @doc fen.extensions.steering.register
;; kind: function
;; signature: (register api) -> true
;; summary: Register the steering introspect snapshot and the default late-order input handler that drives steering/follow-up queueing.
;; tags: steering register input
(fn M.register [api]
  (api.register :introspect
    {:name :queues
     :description "Pending steering/follow-up queue depths and drain modes"
     :snapshot (fn [_] (service.queue-info))})
  ;; Default/fallback input handler at a late order so other extensions
  ;; (macro expansion, planners, subagent routing) can transform or consume
  ;; input before steering resolves it. Resolves through the module table at
  ;; call time so /reload stays safe.
  (api.register :input-handler
    {:name :steering
     :order 1000
     :handle (fn [input ctx] (service.handle-input input ctx))})
  true)

M
