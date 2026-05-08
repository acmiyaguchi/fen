(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

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

;; @doc fen.core.extensions.register.hook.run-before-tool
;; kind: function
;; signature: (run-before-tool tool-name args ctx) -> {:block? boolean :reason string|nil}
;; summary: Run registered before-tool hooks in order and return the first veto decision, or an explicit non-blocking decision.
;; tags: extensions hooks tools
(fn M.run-before-tool [tool-name args ctx]
  "Fire all :before-tool hooks; first veto wins."
  (var blocked nil)
  (each [_ entry (ipairs state.hooks.before-tool) &until blocked]
    (let [(ok? result) (pcall entry.fn tool-name args ctx)]
      (when (and ok? (= (type result) :table) result.block)
        (set blocked {:block? true :reason result.reason}))))
  (or blocked {:block? false}))

M
