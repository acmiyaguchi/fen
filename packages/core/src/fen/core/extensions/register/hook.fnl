(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn M.register [spec owner handle-result]
  (when (not= (type (?. spec :before-tool)) :function)
    (error "register :hook requires {:before-tool fn}"))
  (let [(entry unregister) (util.add-tagged! state.hooks.before-tool
                                             {:fn spec.before-tool}
                                             owner)]
    (handle-result :hook :before-tool owner unregister)))

(fn M.unregister-by-owner [owner]
  (util.remove-where state.hooks.before-tool
                     (fn [e _] (= e.__owner owner))))

(fn M.run-before-tool [tool-name args ctx]
  "Fire all :before-tool hooks; first veto wins."
  (var blocked nil)
  (each [_ entry (ipairs state.hooks.before-tool) &until blocked]
    (let [(ok? result) (pcall entry.fn tool-name args ctx)]
      (when (and ok? (= (type result) :table) result.block)
        (set blocked {:block? true :reason result.reason}))))
  (or blocked {:block? false}))

M
