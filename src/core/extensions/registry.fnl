(local state (require :core.extensions.state))
(local util (require :core.extensions.util))
(local prompt (require :core.extensions.prompt))
(local presenter (require :core.extensions.presenter))

(local M {})

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

(fn register-tool [spec owner]
  (when (or (not spec) (not spec.name))
    (error "register :tool requires {:name ...}"))
  (let [tagged (util.deep-copy spec)]
    (tset tagged :__owner owner)
    (table.insert state.tools-extra tagged)
    (handle-result :tool spec.name owner
      (fn []
        (util.remove-where state.tools-extra (fn [t _] (= t tagged)))))))

(fn register-command [spec owner]
  (when (or (not spec) (not spec.name) (not spec.handler))
    (error "register :command requires {:name :handler ...}"))
  (let [name spec.name
        record (util.deep-copy spec)]
    (tset record :owner owner)
    (tset state.commands-extra name record)
    (handle-result :command name owner
      (fn []
        (when (= (?. state.commands-extra name :owner) owner)
          (tset state.commands-extra name nil))))))

(fn register-hook [spec owner]
  (when (or (not spec) (not spec.before-tool))
    (error "register :hook requires {:before-tool fn} (v1 only phase)"))
  (let [entry {:fn spec.before-tool :owner owner}]
    (table.insert state.hooks.before-tool entry)
    (handle-result :hook :before-tool owner
      (fn []
        (util.remove-where state.hooks.before-tool
                           (fn [e _] (= e entry)))))))

(fn M.register [kind spec owner]
  (if (= kind :tool) (register-tool spec owner)
      (= kind :command) (register-command spec owner)
      (= kind :presenter) (presenter.register-presenter spec owner handle-result)
      (= kind :hook) (register-hook spec owner)
      (= kind :system-prompt) (prompt.contribute (or spec.text (. spec :text-or-fn)) spec owner)
      (error (.. "unknown register kind: " (tostring kind)))))

(fn M.run-before-tool [tool-name args ctx]
  "Fire all :before-tool hooks; first veto wins."
  (var blocked nil)
  (each [_ entry (ipairs state.hooks.before-tool) &until blocked]
    (let [(ok? result) (pcall entry.fn tool-name args ctx)]
      (when (and ok? (= (type result) :table) result.block)
        (set blocked {:block? true :reason result.reason}))))
  (or blocked {:block? false}))

(fn M.merged-tools [base]
  "Return base ++ extension-contributed tools."
  (let [out []]
    (each [_ t (ipairs (or base []))] (table.insert out t))
    (each [_ t (ipairs state.tools-extra)] (table.insert out t))
    out))

(fn M.unregister-by-owner [owner]
  "Drop every registration tagged with owner."
  (util.remove-where state.tools-extra
                     (fn [t _] (= t.__owner owner)))
  (each [name rec (pairs state.commands-extra)]
    (when (= rec.owner owner)
      (tset state.commands-extra name nil)))
  (util.remove-where state.presenters
                     (fn [p _] (= p.__owner owner)))
  (presenter.promote-ui-slot!)
  (util.remove-where state.hooks.before-tool
                     (fn [e _] (= e.owner owner)))
  (each [_ slot (ipairs prompt.PROMPT-SLOTS)]
    (util.remove-where (. state.prompt-fragments slot)
                       (fn [e _] (= e.owner owner))))
  (each [_ bucket (pairs state.handlers)]
    (util.remove-where bucket (fn [e _] (= e.owner owner))))
  (tset state.extensions owner nil)
  nil)

M
