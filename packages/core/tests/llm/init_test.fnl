(local extensions (require :fen.core.extensions))
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
