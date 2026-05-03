(local extensions (require :fen.core.extensions))
(local llm (require :fen.core.llm))

(before_each (fn [] (extensions.reset!)))

(describe "core.llm provider dispatch"
  (fn []
    (it "dispatches complete through the extension provider registry by api"
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
              out (llm.complete :fake-api :m ctx opts)]
          (assert.are.equal :assistant out.role)
          (assert.are.equal :m seen.model)
          (assert.are.equal ctx seen.context)
          (assert.are.equal opts seen.options))))

    (it "dispatches complete through the extension provider registry by name"
      (fn []
        (extensions.register
          :provider
          {:name :fake
           :api :fake-api
           :complete (fn [model _context _options]
                       {:role :assistant
                        :provider :fake
                        :model model
                        :stop-reason :end-turn
                        :content []})}
          :test)
        (let [out (llm.complete :fake :m {} {})]
          (assert.are.equal :m out.model))))))
