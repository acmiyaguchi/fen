;; Tests for the slash command dispatcher and built-in commands.
;;
;; The dispatcher is `extensions.dispatch-command`. Handlers emit through
;; the bus, so tests subscribe a `:*` listener to assert on emitted events.

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
   :list-providers-by-api provider-registry.list-by-api
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})
(local ext-api (require :fen.core.extensions.test_api))

(fn fresh-bus []
  "Reset the registry, force first-party command extensions to re-load against the
   fresh state (so its `(api.register :command ...)` calls populate the
   empty registry), and return a list that captures every emitted event."
  (extensions.reset!)
  (each [_ mod (ipairs [:fen.extensions.essentials
                        :fen.extensions.sessions
                        :fen.extensions.status
                        :fen.extensions.queue
                        :fen.extensions.prompt
                        :fen.extensions.extensions_inspector])]
    (tset package.loaded mod nil))
  (let [seen []]
    (extensions.on :* (fn [ev] (table.insert seen ev)))
    (each [_ name (ipairs [:essentials :sessions :status :queue :prompt :extensions_inspector])]
      (let [mod (require (.. "fen.extensions." (tostring name)))
            api (ext-api.make-runtime-api name)]
        (mod.register api)))
    seen))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(describe "extensions.dispatch-command"
  (fn []
    (it "/status toggles the status panel"
      (fn []
        (tset package.loaded :fen.version "test-version")
        (tset package.loaded :fen.extensions.tui.state nil)
        (let [panel-state (require :fen.extensions.status.state.status)]
          (set panel-state.visible? false)
          (let [seen (fresh-bus)
                state {:opts {:provider :openai}
                       :agent {:model :gpt-test
                               :provider-name :openai
                               :max-tokens 123
                               :system-prompt "system"
                               :messages []}
                       :session nil}]
            (extensions.dispatch-command "/status" state)
            (assert.is_true panel-state.visible?)
            (let [ev (find-event seen :info)]
              (assert.is_not_nil ev)
              (assert.is_not_nil
                (string.find ev.text "status panel: on" 1 true)))
            ;; Second invocation closes the panel.
            (extensions.dispatch-command "/status" state)
            (assert.is_false (or panel-state.visible? false))))))

    (it "unknown commands emit a friendly error"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/no-such-cmd" {})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "unknown command" 1 true))))))

    (it "idle-only commands are blocked while busy"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/new" {:busy? true})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "disabled while the agent is running"
                            1 true))))))

    (it "handler errors are pcall'd into a bus :error"
      (fn []
        (extensions.reset!)
        (let [api (ext-api.make-runtime-api :test-owner)
              seen []]
          (extensions.on :* (fn [ev] (table.insert seen ev)))
          (api.register :command
                        {:name :crash
                         :handler (fn [_ _] (error "boom"))})
          (extensions.dispatch-command "/crash" {})
          (let [ev (find-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_not_nil
              (string.find ev.error "/crash:" 1 true))
            (assert.is_not_nil
              (string.find ev.error "boom" 1 true))))))

    (it "/prompt toggles the prompt-fragments panel"
      (fn []
        (let [panel-state (require :fen.extensions.prompt.state.prompt)]
          (set panel-state.visible? false)
          (let [seen (fresh-bus)
                api (ext-api.make-runtime-api :prompt-test)]
            (api.prompt "body" {:order 10
                                :id :body
                                :title "Body"
                                :description "Main prompt body."})
            (extensions.dispatch-command "/prompt" {:agent {:system-prompt "hello prompt"}})
            (assert.is_true panel-state.visible?)
            (let [ev (find-event seen :info)]
              (assert.is_not_nil ev)
              (assert.is_not_nil
                (string.find ev.text "prompt panel: on" 1 true)))))))

    (it "/prompt rendered emits the rendered system prompt"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/prompt rendered" {:agent {:system-prompt "hello prompt"}})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.are.equal "hello prompt" ev.text)))))

    (it "/help lists registered commands"
      (fn []
        (let [seen (fresh-bus)]
          (extensions.dispatch-command "/help" {})
          (let [ev (find-event seen :assistant-text)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "/new" 1 true))
            (assert.is_not_nil (string.find ev.text "/prompt" 1 true))
            (assert.is_nil (string.find ev.text "/prompt-fragments" 1 true))
            (assert.is_not_nil (string.find ev.text "/reload" 1 true))
            (assert.is_not_nil (string.find ev.text "/status" 1 true))))))))
