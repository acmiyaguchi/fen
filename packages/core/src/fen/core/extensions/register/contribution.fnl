;; Shared scaffolding for owner-tagged array contribution registries.
;;
;; Presenter-facing contribution kinds such as controls, status items, and
;; panels differ in validation/defaults and listed fields, but share the same
;; append/unregister/list shape.

(local util (require :fen.core.extensions.util))

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

(fn append-tagged! [bucket record owner]
  (tset record :__owner owner)
  (table.insert bucket record)
  (util.bump-registry-version!)
  (values record
          (fn []
            (util.remove-where bucket (fn [entry _] (= entry record))))))

;; @doc fen.core.extensions.register.contribution.register
;; kind: function
;; signature: (register opts spec owner handle-result) -> register-result
;; summary: Validate, default, and append one owner-tagged array contribution.
;; tags: extensions register contribution
(fn M.register [opts spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error (.. "register :" (tostring opts.kind) " requires {:name ...}")))
  (when opts.validate
    (opts.validate spec))
  (let [spec* (util.deep-copy spec)]
    (apply-defaults! spec* opts.defaults)
    (let [(record unregister) (append-tagged! opts.bucket spec* owner)]
      (handle-result opts.kind record.name owner unregister))))

;; @doc fen.core.extensions.register.contribution.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner opts owner) -> nil
;; summary: Remove all contributions tagged with owner from an array registry bucket.
;; tags: extensions register contribution reload
(fn M.unregister-by-owner [opts owner]
  (util.remove-where opts.bucket
                     (fn [rec _] (= rec.__owner owner))))

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
