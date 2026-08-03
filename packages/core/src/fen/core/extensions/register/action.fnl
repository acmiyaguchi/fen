;; Typed, owner-scoped actions for privileged harness and headless callers.
;; Actions are deliberately separate from tools: they are not provider-visible,
;; do not enter transcript semantics, and do not run tool policy hooks.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local json-schema (require :fen.util.json_schema))

(local M {})

(fn ensure-state! []
  (when (= state.actions-extra nil)
    (set state.actions-extra [])))

(fn same-owner-name? [record owner name]
  (and (= (tostring record.__owner) (tostring owner))
       (= (tostring record.name) (tostring name))))

(fn M.register [spec owner handle-result]
  (ensure-state!)
  (when (or (not spec) (not spec.name))
    (error "register :action requires {:name ...}"))
  (when (not= (type spec.description) :string)
    (error "register :action requires {:description string}"))
  (when (not= (type spec.parameters) :table)
    (error "register :action requires {:parameters json-schema}"))
  (when (not= (type spec.invoke) :function)
    (error "register :action requires {:invoke fn}"))
  ;; An owner names its action namespace, so replacement is deterministic while
  ;; two owners may expose the same action name.
  (util.remove-where state.actions-extra
                     (fn [record _] (same-owner-name? record owner spec.name)))
  (let [(record unregister) (util.add-tagged! state.actions-extra spec owner)]
    (handle-result :action spec.name owner unregister)))

(fn M.unregister-by-owner [owner]
  (ensure-state!)
  (util.remove-where state.actions-extra
                     (fn [record _] (= record.__owner owner))))

(fn by-owner-name [a b]
  (let [ao (tostring a.owner)
        bo (tostring b.owner)]
    (if (not= ao bo)
        (< ao bo)
        (< (tostring a.name) (tostring b.name)))))

(fn M.list []
  "Return harness-safe descriptors without executable callbacks."
  (ensure-state!)
  (let [out []]
    (each [_ record (ipairs state.actions-extra)]
      (table.insert out {:owner record.__owner
                         :name record.name
                         :description record.description
                         :parameters record.parameters}))
    (table.sort out by-owner-name)
    out))

(fn find [owner name]
  (ensure-state!)
  (var found nil)
  (each [_ record (ipairs state.actions-extra)]
    (when (and (not found) (same-owner-name? record owner name))
      (set found record)))
  found)

(fn failure [owner name error ?extra]
  (let [out {:ok false :owner owner :action name :error error}]
    (each [k v (pairs (or ?extra {}))]
      (tset out k v))
    out))

(fn M.invoke [owner name args ctx]
  "Validate arguments and invoke an action, always returning a structured result.
   Action bodies return a state payload or {:ok true :state ...} on success,
   and {:ok false :error ... :state ...} for a domain-level rejection after
   schema validation."
  (let [record (find owner name)]
    (if (not record)
        (failure owner name "unknown action")
        (let [safe-args (or args {})
              (schema-ok? valid? errors)
              (pcall json-schema.validate record.parameters safe-args)]
          (if (not schema-ok?)
              (failure owner name "action schema validation failed"
                       {:details [{:field "arguments" :message (tostring valid?)}]})
              (not valid?)
              (failure owner name "invalid action arguments" {:details errors})
              (let [(ok? value-or-error)
                    (xpcall (fn [] (record.invoke safe-args ctx)) debug.traceback)]
                (if (not ok?)
                    (failure owner name "action invocation failed"
                             {:details [{:field "action" :message (tostring value-or-error)}]})
                    (and (= (type value-or-error) :table)
                         (= value-or-error.ok false))
                    (failure owner name (or value-or-error.error "action rejected")
                             {:details value-or-error.details
                              :state value-or-error.state})
                    (and (= (type value-or-error) :table)
                         (= value-or-error.ok true))
                    {:ok true :owner record.__owner :action record.name
                     :state value-or-error.state}
                    {:ok true :owner record.__owner :action record.name
                     :state value-or-error})))))))

M
