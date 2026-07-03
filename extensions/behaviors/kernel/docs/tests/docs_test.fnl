;; Tests for the docs extension command.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local hook-registry (require :fen.core.extensions.register.hook))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local presenter-registry (require :fen.core.extensions.register.presenter))
(local provider-registry (require :fen.core.extensions.register.provider))
(local auth-backend-registry (require :fen.core.extensions.register.auth_backend))
(local session-backend-registry (require :fen.core.extensions.register.session_backend))
(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})
(local extensions
  {:reset! test-api.reset!
   :emit events.emit
   :on events.on
   :register register-registry.register
   :unregister-by-owner register-registry.unregister-by-owner
   :list register-registry.list
   :dispatch-command command-registry.dispatch
   :merged-tools tool-registry.merged
   :run-before-tool hook-registry.run-before-tool
   :prompt (fn [text-or-fn ?opts owner]
             (prompt-registry.contribute text-or-fn ?opts owner handle-result))
   :render-prompt prompt-registry.render
   :active-presenter presenter-registry.active-presenter
   :init-active-presenter presenter-registry.init-active-presenter
   :run-active-presenter presenter-registry.run-active-presenter
   :shutdown-active-presenter presenter-registry.shutdown-active-presenter
   :find-provider provider-registry.find
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})
(local ext-api (require :fen.core.extensions.test_api))

(fn fresh-docs []
  (extensions.reset!)
  (tset package.loaded :fen.extensions.docs nil)
  (let [seen []]
    (extensions.on :* (fn [ev] (table.insert seen ev)))
    (let [mod (require :fen.extensions.docs)
          api (ext-api.make-runtime-api :docs)]
      (mod.register api))
    seen))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(describe "docs extension"
  (fn []
    (it "/docs toggles the docs panel"
      (fn []
        (let [panel-state (require :fen.extensions.docs.state)]
          (set panel-state.visible? false)
          (set panel-state.selected-topic nil)
          (let [seen (fresh-docs)]
            (extensions.dispatch-command "/docs" {})
            (assert.is_true panel-state.visible?)
            (let [ev (find-event seen :info)]
              (assert.is_not_nil ev)
              (assert.is_not_nil
                (string.find ev.text "docs panel: on" 1 true)))))))

    (it "/docs can show contract details"
      (fn []
        (let [seen (fresh-docs)]
          (extensions.dispatch-command "/docs types Message" {})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "# Message" 1 true))
            (assert.is_not_nil (string.find ev.text "Variants:" 1 true))))))

    (it "registers a fen_docs tool for model-facing docs lookup"
      (fn []
        (fresh-docs)
        (let [tools (extensions.merged-tools [])]
          (var found nil)
          (each [_ tool (ipairs tools)]
            (when (= tool.name :fen_docs)
              (set found tool)))
          (assert.is_not_nil found)
          (let [res (found.execute {:topic :register-kinds :name :tool} {})
                text (. res :content 1 :text)]
            (assert.is_false (or res.is-error? false))
            (assert.is_not_nil (string.find text "# tool" 1 true))
            (assert.is_not_nil (string.find text ":execute" 1 true))))))

    (it "fen_docs can search docs"
      (fn []
        (fresh-docs)
        (let [tools (extensions.merged-tools [])]
          (var found nil)
          (each [_ tool (ipairs tools)]
            (when (= tool.name :fen_docs)
              (set found tool)))
          (assert.is_not_nil found)
          (let [res (found.execute {:query "ToolResultMessage"} {})
                text (. res :content 1 :text)]
            (assert.is_false (or res.is-error? false))
            (assert.is_not_nil (string.find text "# Docs search" 1 true))
            (assert.is_not_nil (string.find text "types/ToolResultMessage" 1 true))))))))
