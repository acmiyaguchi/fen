;; Status item kind. Presenter-neutral blocks composed by active presenters
;; (Waybar/Polybar-style), rather than mutation of one shared status string.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn valid-side? [side]
  (or (= side :left) (= side :right)))

;; @doc fen.core.extensions.register.status.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate a status-line contributor, fill default side/order fields, and append it to the status registry.
;; tags: extensions register status
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :status requires {:name ...}"))
  (when (and spec.side (not (valid-side? spec.side)))
    (error "register :status side must be :left or :right"))
  (when (not= (type spec.render) :function)
    (error "register :status requires {:render fn}"))
  (let [spec* (util.deep-copy spec)]
    (when (= spec*.side nil) (set spec*.side :left))
    (when (= spec*.order nil) (set spec*.order 50))
    (let [(record unregister) (util.add-tagged! state.status-extra spec* owner)]
      (handle-result :status spec.name owner unregister))))

;; @doc fen.core.extensions.register.status.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all status contributors installed by owner while preserving contributors from other extensions.
;; tags: extensions register status reload
(fn M.unregister-by-owner [owner]
  (util.remove-where state.status-extra
                     (fn [s _] (= s.__owner owner))))

(fn by-order [a b]
  (let [ao (or a.order 50)
        bo (or b.order 50)]
    (if (not= ao bo) (< ao bo)
        (not= (tostring (or a.__owner "")) (tostring (or b.__owner "")))
        (< (tostring (or a.__owner "")) (tostring (or b.__owner "")))
        (< (tostring (or a.name "")) (tostring (or b.name ""))))))

;; @doc fen.core.extensions.register.status.list
;; kind: function
;; signature: (list) -> [StatusItem]
;; summary: Return status contributors sorted by order, owner, and name for deterministic presenter rendering.
;; tags: extensions status introspection
(fn M.list []
  (let [out []]
    (each [_ rec (ipairs state.status-extra)]
      (table.insert out {:name rec.name
                         :owner rec.__owner
                         :side rec.side
                         :order rec.order
                         :render rec.render}))
    (table.sort out by-order)
    out))

M
