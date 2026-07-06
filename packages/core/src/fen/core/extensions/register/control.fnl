(local state (require :fen.core.extensions.state))
(local contribution (require :fen.core.extensions.register.contribution))

(local M {})

(local opts
  {:kind :control
   :bucket state.controls-extra
   :list-fields [:description :keys :order]})

;; @doc fen.core.extensions.register.control.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and append a presenter-neutral control contribution with owner tagging for reload cleanup.
;; tags: extensions register controls
(fn M.register [spec owner handle-result]
  (contribution.register opts spec owner handle-result))

;; @doc fen.core.extensions.register.control.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all control contributions installed by owner from the ordered controls registry.
;; tags: extensions register controls reload
(fn M.unregister-by-owner [owner]
  (contribution.unregister-by-owner opts owner))

;; @doc fen.core.extensions.register.control.list
;; kind: function
;; signature: (list) -> [ControlInfo]
;; summary: Return control metadata for presenters and docs, including keys/order while hiding mutable registry records.
;; tags: extensions controls introspection
(fn M.list []
  (contribution.list opts))

M
