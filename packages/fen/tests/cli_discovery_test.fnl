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
