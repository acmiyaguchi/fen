;; Shared scaffolding for owner-tagged array contribution registries.

(local util (require :fen.core.extensions.util))
(local contrib (require :fen.core.extensions.contrib))

(local M {})

(fn M.by-order [a b]
  (let [ao (or a.order 50)
        bo (or b.order 50)]
    (if (not= ao bo) (< ao bo)
        (not= (tostring (or a.owner a.__owner ""))
              (tostring (or b.owner b.__owner "")))
        (< (tostring (or a.owner a.__owner ""))
           (tostring (or b.owner b.__owner "")))
        (< (tostring (or a.name "")) (tostring (or b.name ""))))))

(fn apply-defaults! [record defaults]
  (each [k v (pairs (or defaults {}))]
    (when (= (. record k) nil)
      (tset record k v))))

;; @doc fen.core.extensions.register.contribution.register
;; kind: function
;; signature: (register opts spec owner handle-result) -> register-result
;; summary: Validate, default, and add one owner-tagged array contribution to opts.view.
;; tags: extensions register contribution
(fn M.register [opts spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error (.. "register :" (tostring opts.kind) " requires {:name ...}")))
  (when opts.validate
    (opts.validate spec))
  (let [spec* (util.deep-copy spec)]
    (apply-defaults! spec* opts.defaults)
    (let [(record unregister) (contrib.add! owner opts.view nil spec*)]
      (handle-result opts.kind record.name owner unregister))))

;; @doc fen.core.extensions.register.contribution.list
;; kind: function
;; signature: (list opts) -> table
;; summary: Return introspection records copied from an owner-tagged array registry bucket.
;; tags: extensions register contribution introspection
(fn M.list [opts]
  (let [out []]
    (each [_ rec (ipairs opts.bucket)]
      (let [item {:name rec.name :owner rec.__owner}]
        (each [_ field (ipairs (or opts.list-fields []))]
          (tset item field (. rec field)))
        (table.insert out item)))
    (when opts.sort-by-order?
      (table.sort out M.by-order))
    out))

M
