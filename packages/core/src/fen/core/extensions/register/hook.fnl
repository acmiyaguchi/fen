(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))

(local M {})

;; @doc fen.core.extensions.register.hook.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and append a before-tool hook contribution that can inspect or veto pending tool execution.
;; tags: extensions register hooks tools
(fn M.register [spec owner handle-result]
  (when (not= (type (?. spec :before-tool)) :function)
    (error "register :hook requires {:before-tool fn}"))
  (let [(entry unregister) (util.add-tagged! state.hooks.before-tool
                                             {:fn spec.before-tool}
                                             owner)]
    (handle-result :hook :before-tool owner unregister)))

;; @doc fen.core.extensions.register.hook.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all before-tool hooks installed by owner during extension reload or teardown.
;; tags: extensions hooks reload
(fn M.unregister-by-owner [owner]
  (util.remove-where state.hooks.before-tool
                     (fn [e _] (= e.__owner owner))))

;; @doc fen.core.extensions.register.hook.list
;; kind: function
;; signature: (list) -> [HookInfo]
;; summary: Return hook contributions without exposing hook functions.
;; tags: extensions hooks introspection
(fn M.list []
  (let [out []]
    (each [_ rec (ipairs state.hooks.before-tool)]
      (table.insert out {:owner rec.__owner :event :before-tool}))
    out))

;; @doc fen.core.extensions.register.hook.run-before-tool
;; kind: function
;; signature: (run-before-tool ctx) -> {:block? boolean :reason string|nil}
;; summary: Run registered before-tool policy hooks in registration order; the first block wins and hook failures fail closed.
;; tags: extensions hooks tools policy
(fn M.run-before-tool [ctx]
  "Run all hooks in deterministic registration order until one blocks."
  (var blocked nil)
  (each [_ entry (ipairs state.hooks.before-tool) &until blocked]
    (let [(ok? result) (xpcall #(entry.fn ctx) debug.traceback)]
      (if (not ok?)
          (let [reason (.. "policy hook failed"
                            " (owner " (tostring entry.__owner) "): "
                            (tostring result))]
            (events.emit {:type :extension-error
                          :owner entry.__owner
                          :event :before-tool
                          :error reason
                          :traceback (tostring result)})
            (set blocked {:block? true
                          :reason reason
                          :policy-hook-failed? true
                          :owner entry.__owner}))
          (when (and (= (type result) :table) result.block)
            (set blocked {:block? true
                          :reason result.reason
                          :owner entry.__owner})))))
  (or blocked {:block? false}))

M
