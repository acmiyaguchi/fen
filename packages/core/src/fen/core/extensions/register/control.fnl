(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

;; @doc fen.core.extensions.register.control.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and append a presenter-neutral control contribution with owner tagging for reload cleanup.
;; tags: extensions register controls
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :control requires {:name ...}"))
  (let [(record unregister) (util.add-tagged! state.controls-extra spec owner)]
    (handle-result :control spec.name owner unregister)))

;; @doc fen.core.extensions.register.control.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all control contributions installed by owner from the ordered controls registry.
;; tags: extensions register controls reload
(fn M.unregister-by-owner [owner]
  (util.remove-where state.controls-extra
                     (fn [c _] (= c.__owner owner))))

;; @doc fen.core.extensions.register.control.list
;; kind: function
;; signature: (list) -> [ControlInfo]
;; summary: Return control metadata for presenters and docs, including keys/order while hiding mutable registry records.
;; tags: extensions controls introspection
(fn M.list []
  (let [out []]
    (each [_ rec (ipairs state.controls-extra)]
      (table.insert out {:name rec.name :owner rec.__owner
                         :description rec.description
                         :keys rec.keys
                         :order rec.order}))
    out))

M
