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
;; summary: Register the steering introspect snapshot; the queue service itself is consumed by require.
;; tags: steering register
(fn M.register [api]
  (api.register :introspect
    {:name :queues
     :description "Pending steering/follow-up queue depths and drain modes"
     :snapshot (fn [_] (service.queue-info))})
  true)

M
