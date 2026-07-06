;; Status item kind. Presenter-neutral blocks composed by active presenters
;; (Waybar/Polybar-style), rather than mutation of one shared status string.

(local state (require :fen.core.extensions.state))
(local contribution (require :fen.core.extensions.register.contribution))

(local M {})

(fn valid-side? [side]
  (or (= side :left) (= side :right)))

(fn validate [spec]
  (when (and spec.side (not (valid-side? spec.side)))
    (error "register :status side must be :left or :right"))
  (when (not= (type spec.render) :function)
    (error "register :status requires {:render fn}")))

(local opts
  {:kind :status
   :bucket state.status-extra
   :defaults {:side :left :order 50}
   :validate validate
   :list-fields [:side :order :render]
   :sort-by-order? true})

;; @doc fen.core.extensions.register.status.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate a status-line contributor, fill default side/order fields, and append it to the status registry.
;; tags: extensions register status
(fn M.register [spec owner handle-result]
  (contribution.register opts spec owner handle-result))

;; @doc fen.core.extensions.register.status.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all status contributors installed by owner while preserving contributors from other extensions.
;; tags: extensions register status reload
(fn M.unregister-by-owner [owner]
  (contribution.unregister-by-owner opts owner))

;; @doc fen.core.extensions.register.status.list
;; kind: function
;; signature: (list) -> [StatusItem]
;; summary: Return status contributors sorted by order, owner, and name for deterministic presenter rendering.
;; tags: extensions status introspection
(fn M.list []
  (contribution.list opts))

M
