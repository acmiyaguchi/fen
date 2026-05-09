;; Introspection snapshot register kind. Extensions register cheap read-only
;; snapshot thunks; consumers collect owner-scoped plain data through one
;; pcall-isolated path.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))

(local M {})

(var collecting? false)

(fn ensure-state! []
  (when (= state.introspectors-extra nil)
    (set state.introspectors-extra [])))

(fn M.register [spec owner handle-result]
  (ensure-state!)
  (when (or (not spec) (not spec.name))
    (error "register :introspect requires {:name ...}"))
  (when (not= (type spec.snapshot) :function)
    (error "register :introspect requires {:snapshot fn}"))
  (let [(record unregister) (util.add-tagged! state.introspectors-extra spec owner)]
    (handle-result :introspect spec.name owner unregister)))

(fn M.unregister-by-owner [owner]
  (ensure-state!)
  (util.remove-where state.introspectors-extra
                     (fn [rec _] (= rec.__owner owner))))

(fn by-owner-name [a b]
  (let [ao (tostring (or a.__owner a.owner ""))
        bo (tostring (or b.__owner b.owner ""))]
    (if (not= ao bo)
        (< ao bo)
        (< (tostring (or a.name "")) (tostring (or b.name ""))))))

(fn M.list []
  (ensure-state!)
  (let [out []]
    (each [_ rec (ipairs state.introspectors-extra)]
      (table.insert out {:name rec.name
                         :owner rec.__owner
                         :description rec.description
                         :snapshot rec.snapshot}))
    (table.sort out by-owner-name)
    out))

(fn sanitize [v seen]
  "Copy snapshot output into plain JSON-friendly data. Unsupported values are
  stringified so one bad field does not poison the whole agent_state render."
  (let [tv (type v)]
    (if (= tv :table)
        (if (. seen v)
            "<cycle>"
            (let [out {}]
              (tset seen v true)
              (each [k vv (pairs v)]
                (let [kt (type k)]
                  (when (or (= kt :string) (= kt :number) (= kt :boolean))
                    (tset out k (sanitize vv seen)))))
              (tset seen v nil)
              out))
        (or (= tv :string) (= tv :number) (= tv :boolean) (= tv :nil))
        v
        (tostring v))))

(fn emit-snapshot-error [owner name err]
  (events.emit {:type :extension-error
                :owner owner
                :event :introspect
                :introspector name
                :error (tostring err)}))

(fn collect-one [rec ctx]
  (let [(ok? value-or-err) (xpcall (fn [] (rec.snapshot ctx)) debug.traceback)]
    (if ok?
        (sanitize value-or-err {})
        (do
          (emit-snapshot-error rec.__owner rec.name value-or-err)
          {:error (tostring value-or-err)}))))

(fn M.collect [?owner ?ctx]
  "Return owner-scoped snapshot outputs. If owner is supplied, only collect
  snapshots for that owner. Snapshot failures become {:error ...} records."
  (ensure-state!)
  (if collecting?
      {:error "introspection already in progress"}
      (let [out {}]
        (set collecting? true)
        (each [_ rec (ipairs state.introspectors-extra)]
          (when (or (= ?owner nil) (= (tostring rec.__owner) (tostring ?owner)))
            (let [owner rec.__owner
                  name rec.name]
              (when (= (. out owner) nil)
                (tset out owner {}))
              (tset (. out owner) name (collect-one rec ?ctx)))))
        (set collecting? false)
        out)))

M
