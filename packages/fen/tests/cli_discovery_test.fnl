(local discovery (require :fen.cli_discovery))
(local registry (require :fen.core.extensions.register))

(describe "fen.cli_discovery"
  (fn []
    (after_each (fn []
                  (registry.unregister-by-owner :cli-discovery-test)))

    (it "exposes the documented live registry surfaces"
      (fn []
        (assert.same [:commands :tools :providers :models :presenters
                      :session-backends :extensions :skills :agents]
                     (discovery.kinds))))

    (it "provides named surfaces as the discovery bootstrap"
      (fn []
        (let [surfaces (discovery.surfaces)]
          (assert.are.equal :tools (. surfaces 2 :name))
          (assert.are.equal "Agent tools available to a run."
                            (. surfaces 2 :description)))))

    (it "returns an error for an unknown surface"
      (fn []
        (let [(items err) (discovery.list :widgets {})]
          (assert.is_nil items)
          (assert.are.equal "unknown discovery surface: widgets" err))))

    (it "includes extension-contributed commands with ownership metadata"
      (fn []
        (registry.register :command
                           {:name :review-now
                            :description "Review the current changes"
                            :handler (fn [])}
                           :cli-discovery-test)
        (let [items (discovery.list :commands {})]
          (var found nil)
          (each [_ item (ipairs items)]
            (when (= item.name :review-now) (set found item)))
          (assert.is_not_nil found)
          (assert.are.equal :cli-discovery-test found.owner)
          (assert.are.equal "Review the current changes" found.description))))

    (it "uses secret-free provider introspection"
      (fn []
        (registry.register :provider
                           {:name :secret-provider
                            :api :mock
                            :api-key "do-not-print"
                            :default-model :secret-model
                            :models [:secret-model]
                            :complete (fn [])}
                           :cli-discovery-test)
        (let [items (discovery.list :providers {:provider :secret-provider})
              provider (. items 1)]
          (assert.are.equal :secret-provider provider.name)
          (assert.are.equal :configured provider.auth.status)
          (assert.is_nil provider.api-key))))

    (it "keeps provider readiness offline unless connectivity is explicitly checked"
      (fn []
        (var calls 0)
        (registry.register :provider
                           {:name :probe-provider
                            :api :mock
                            :api-key "do-not-print"
                            :default-model :probe
                            :list-models (fn [_]
                                           (set calls (+ calls 1))
                                           [{:id :probe}])
                            :complete (fn [])}
                           :cli-discovery-test)
        (let [offline (. (discovery.list :providers {:provider :probe-provider}) 1)]
          (assert.are.equal 0 calls)
          (assert.is_true offline.registered)
          (assert.is_true offline.configured)
          (assert.are.equal :ready offline.readiness.status)
          (assert.are.equal :not-checked offline.connectivity.status))
        (let [checked (. (discovery.list :providers {:provider :probe-provider
                                                      :check? true}) 1)]
          (assert.are.equal 1 calls)
          (assert.is_true checked.connectivity.checked)
          (assert.is_true checked.connectivity.reachable)
          (assert.are.equal :reachable checked.connectivity.status))))

    (it "returns stable secret-free connectivity failures"
      (fn []
        (registry.register :provider
                           {:name :failed-probe
                            :api :mock
                            :api-key "super-secret-token"
                            :list-models (fn [_]
                                           (error "HTTP 401 super-secret-token"))
                            :complete (fn [])}
                           :cli-discovery-test)
        (let [provider (. (discovery.list :providers {:provider :failed-probe
                                                       :check? true}) 1)
              rendered (discovery.render {:items [provider]} true)]
          (assert.are.equal :unreachable provider.connectivity.status)
          (assert.are.equal :authentication-failed provider.connectivity.reason)
          (assert.is_nil (string.find rendered "super-secret-token" 1 true)))))

    (it "lists models with canonical provider-qualified ids"
      (fn []
        (registry.register :provider
                           {:name :catalog-provider
                            :api :mock
                            :default-model :alpha
                            :models [:alpha :beta]
                            :complete (fn [])}
                           :cli-discovery-test)
        (let [items (discovery.list :models {:provider :catalog-provider})]
          (assert.are.equal 2 (length items))
          (assert.are.equal "catalog-provider/alpha"
                            (tostring (. items 1 :canonical-id)))
          (assert.is_true (. items 1 :default?)))))

    (it "merges every available provider's catalog with --all"
      (fn []
        (registry.register :provider
                           {:name :ready-provider
                            :api :mock
                            :default-model :alpha
                            :models [:alpha :beta]
                            :complete (fn [])}
                           :cli-discovery-test)
        (registry.register :provider
                           {:name :other-provider
                            :api :mock
                            :default-model :gamma
                            :models [:gamma]
                            :complete (fn [])}
                           :cli-discovery-test)
        (let [items (discovery.list :models {:all? true})
              seen {}]
          (each [_ item (ipairs items)]
            (tset seen (tostring item.provider) true)
            (assert.is_not_nil item.provider)
            (assert.is_not_nil item.canonical-id)
            (assert.is_true item.available?))
          (assert.is_true (. seen "ready-provider"))
          (assert.is_true (. seen "other-provider")))))

    (it "omits unavailable providers from the --all catalog"
      (fn []
        (registry.register :provider
                           {:name :configured-provider
                            :api :mock
                            :default-model :alpha
                            :models [:alpha]
                            :complete (fn [])}
                           :cli-discovery-test)
        (registry.register :provider
                           {:name :gated-provider
                            :api :mock
                            :auth-backend :cli-discovery-test-missing-backend
                            :default-model :locked
                            :models [:locked]
                            :complete (fn [])}
                           :cli-discovery-test)
        (let [all-items (discovery.list :models {:all? true})
              plain-items (discovery.list :models {})]
          (var all-gated nil)
          (each [_ item (ipairs all-items)]
            (when (= (tostring item.provider) "gated-provider")
              (set all-gated item)))
          (assert.is_nil all-gated)
          (var plain-gated nil)
          (each [_ item (ipairs plain-items)]
            (when (= (tostring item.provider) "gated-provider")
              (set plain-gated item)))
          (assert.is_not_nil plain-gated)
          (assert.is_false plain-gated.available?))))

    (it "reports per-entry catalog-status for --all rows"
      (fn []
        (registry.register :provider
                           {:name :dynamic-fail-provider
                            :api :mock
                            :default-model :alpha
                            :models [:alpha]
                            :list-models (fn [] (error "boom"))
                            :complete (fn [])}
                           :cli-discovery-test)
        (let [items (discovery.list :models {:all? true})]
          (var row nil)
          (each [_ item (ipairs items)]
            (when (= (tostring item.provider) "dynamic-fail-provider")
              (set row item)))
          (assert.is_not_nil row)
          (assert.are.equal :fallback row.catalog-status))))

    (it "renders script output as JSON without changing its payload"
      (fn []
        (let [text (discovery.render {:surface :tools
                                      :items [{:name :read :owner :builtin}]}
                                    true)]
          (assert.is_truthy (string.find text "\"surface\":\"tools\"" 1 true))
          (assert.is_truthy (string.find text "\"name\":\"read\"" 1 true)))))

    (it "renders a terse human-readable list when JSON was not requested"
      (fn []
        (assert.are.equal "read\tRead a file\towner=builtin"
                          (discovery.render {:items [{:name :read
                                                       :description "Read a file"
                                                       :owner :builtin}]}
                                            false))))))
