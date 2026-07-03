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
(local llm (require :fen.core.llm))

(before_each (fn [] (extensions.reset!)))

(describe "core.llm provider dispatch"
  (fn []
    (it "dispatches complete through the extension provider registry by name"
      (fn []
        (var seen nil)
        (extensions.register
          :provider
          {:name :fake
           :api :fake-api
           :complete (fn [model context options on-event yield-fn]
                       (set seen {: model : context : options : on-event : yield-fn})
                       {:role :assistant
                        :provider :fake
                        :model model
                        :stop-reason :end-turn
                        :content [{:type :text :text "ok"}]})}
          :test)
        (let [ctx {:messages []}
              opts {:api-key "k"}
              out (llm.complete :fake :m ctx opts)]
          (assert.are.equal :assistant out.role)
          (assert.are.equal :m seen.model)
          (assert.are.equal ctx seen.context)
          (assert.are.equal opts seen.options))))

    (it "does not dispatch by shared provider api"
      (fn []
        (extensions.register
          :provider
          {:name :openai
           :api :openai-completions
           :complete (fn [model _context _options]
                       {:role :assistant :provider :openai :model model
                        :stop-reason :end-turn :content []})}
          :test)
        (assert.has_error #(llm.complete :openai-completions :m {} {}))))

    (it "disambiguates providers that share the same api by provider name"
      (fn []
        (var called nil)
        (extensions.register
          :provider
          {:name :openai
           :api :openai-completions
           :complete (fn [model _context _options]
                       (set called :openai)
                       {:role :assistant :provider :openai :model model
                        :stop-reason :end-turn :content []})}
          :test)
        (extensions.register
          :provider
          {:name :ollama
           :api :openai-completions
           :complete (fn [model _context _options]
                       (set called :ollama)
                       {:role :assistant :provider :ollama :model model
                        :stop-reason :end-turn :content []})}
          :test)
        (let [out (llm.complete :ollama :m {} {})]
          (assert.are.equal :ollama called)
          (assert.are.equal :ollama out.provider))))))
