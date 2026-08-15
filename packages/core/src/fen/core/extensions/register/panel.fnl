;; Panel kind: presenter-rendered row region; lower :order sits nearer its placement anchor.
;; Rows are {:text str :attr semantic-style ?:segments [...]}; the presenter owns geometry, error isolation, and final styling.

(local state (require :fen.core.extensions.state))
(local contribution (require :fen.core.extensions.register.contribution))

(local M {})

(fn valid-placement? [p]
  (or (= p :below-status) (= p :above-input)))

(fn validate [spec]
  (when (and spec.placement (not (valid-placement? spec.placement)))
    (error "register :panel placement must be :below-status or :above-input"))
  (when (not= (type spec.render) :function)
    (error "register :panel requires {:render fn}"))
  (when (not= (type spec.height) :function)
    (error "register :panel requires {:height fn}")))

(local opts
  {:kind :panel
   :bucket state.panel-extra
   :defaults {:placement :above-input :order 50}
   :validate validate
   :list-fields [:placement :order :height :render]
   :sort-by-order? true})

;; @doc fen.core.extensions.register.panel.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate a panel contribution, fill default placement/order fields, and append it to the presenter panel registry.
;; tags: extensions register panels ui
(fn M.register [spec owner handle-result]
  (contribution.register opts spec owner handle-result))

;; @doc fen.core.extensions.register.panel.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all panel contributions installed by owner while preserving the shared panel registry table identity.
;; tags: extensions panels reload
(fn M.unregister-by-owner [owner]
  (contribution.unregister-by-owner opts owner))

;; @doc fen.core.extensions.register.panel.list
;; kind: function
;; signature: (list) -> [Panel]
;; summary: Return panel contributions sorted by order, owner, and name for deterministic presenter layout.
;; tags: extensions panels introspection
(fn M.list []
  (contribution.list opts))

M
