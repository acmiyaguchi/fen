;; Focused tests for secret-free provider/model discovery.

(local ext-api (require :fen.core.extensions.test_api))
(local th (require :fen.testing.tools))
(local extensions th.extensions)
(local registry th.registry)
(local json th.json)
(local h th.h)
(local execute th.execute)
(local execute-coop th.execute-coop)
(local first-text th.first-text)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "models introspection tool"
  (fn []
    (after_each (fn [] (extensions.reset!)))

    (fn register-tools []
      (extensions.reset!)
      (tset package.loaded :fen.extensions.agent_state nil)
      (let [mod (require :fen.extensions.agent_state)
            api (ext-api.make-runtime-api :agent_state)]
        (mod.register api))
      (extensions.merged-tools registry))

    (fn context [tools provider model]
      {:agent {:provider-name provider
               :model model
               :messages []
               :tools tools}})

    (it "reports configured and missing providers without credentials"
      (fn []
        (let [tools (register-tools)
              api (ext-api.make-runtime-api :providers-test)]
          (api.register :provider
            {:name :ready :api :test :api-key-var :READY_TEST_KEY
             :default-model :ready-model :complete (fn [])})
          (api.register :provider
            {:name :local :api :test :api-key "top-secret"
             :default-model :local-model :complete (fn [])})
          (h.stub-getenv!
            (fn [name orig]
              (if (= name :READY_TEST_KEY) "configured-secret" (orig name))))
          (let [r (execute tools :models {:action :providers}
                           (context tools :ready :ready-model))
                text (first-text r.content)
                decoded (json.decode text)]
            (assert.is_false r.is-error?)
            (assert.are.equal 2 (length decoded))
            (assert.is_nil (string.find text "configured-secret" 1 true))
            (assert.is_nil (string.find text "top-secret" 1 true))
            (assert.are.equal "configured" (. decoded 1 :auth :status))
            (assert.are.equal "configured" (. decoded 2 :auth :status)))
          (h.restore-getenv!))))

    (it "keeps dynamic catalog credentials provider-scoped"
      (fn []
        (let [tools (register-tools)
              api (ext-api.make-runtime-api :providers-test)]
          (api.register :provider
            {:name :one :api :test :api-key "key-one"
             :list-models (fn [opts]
                            (assert.are.equal "key-one" opts.api-key)
                            [{:id :one-model}])
             :complete (fn [])})
          (api.register :provider
            {:name :two :api :test :api-key "key-two"
             :list-models (fn [opts]
                            (assert.are.equal "key-two" opts.api-key)
                            [{:id :two-model}])
             :complete (fn [])})
          (let [ctx (context tools :one :one-model)]
            ;; Simulate active-provider options containing credentials that must
            ;; never be forwarded to another provider's catalog call.
            (set ctx.state {:opts {:api-key "active-secret"
                                   :base-url "https://active.invalid"}})
            (let [r (execute tools :models {:action :list} ctx)
                  decoded (json.decode (first-text r.content))]
              (assert.is_false r.is-error?)
              (assert.are.equal 2 (length decoded)))))))

    (it "passes the cooperative yield callback into dynamic catalogs"
      (fn []
        (let [tools (register-tools)
              api (ext-api.make-runtime-api :providers-test)]
          (var catalog-yield nil)
          (var yields 0)
          (api.register :provider
            {:name :dynamic :api :test
             :list-models (fn [opts]
                            (set catalog-yield opts.yield)
                            (opts.yield)
                            [{:id :dynamic-model}])
             :complete (fn [])})
          (let [yield-fn (fn [] (set yields (+ yields 1)))
                r (execute-coop tools :models {:action :list}
                                yield-fn (context tools :dynamic :dynamic-model))]
            (assert.is_false r.is-error?)
            (assert.are.equal yield-fn catalog-yield)
            ;; Once before inspection and once inside the provider fixture.
            (assert.are.equal 2 yields)))))

    (it "can expose static unavailable models without querying them"
      (fn []
        (let [tools (register-tools)
              api (ext-api.make-runtime-api :providers-test)]
          (api.register :provider
            {:name :locked :api :test :api-key-var :LOCKED_TEST_KEY
             :models [{:id :known-model}]
             :list-models (fn [_] (error "must not query unavailable provider"))
             :complete (fn [])})
          (h.stub-getenv!
            (fn [name orig]
              (if (= name :LOCKED_TEST_KEY) nil (orig name))))
          (let [ctx (context tools :other :other-model)
                hidden (execute tools :models {:action :list} ctx)
                included (execute tools :models
                                  {:action :list :include_unavailable true} ctx)
                visible (json.decode (first-text included.content))]
            (assert.are.equal 0 (length (json.decode (first-text hidden.content))))
            (assert.are.equal 1 (length visible))
            (assert.is_false (. visible 1 "available?")))
          (h.restore-getenv!))))

    (it "lists selectable models and marks the current model"
      (fn []
        (let [tools (register-tools)
              api (ext-api.make-runtime-api :providers-test)]
          (api.register :provider
            {:name :local :api :test
             :models [{:id :small} {:id :large}]
             :default-model :large :complete (fn [])})
          (let [ctx (context tools :local :large)
                listed (execute tools :models {:action :list :provider "local"} ctx)
                models (json.decode (first-text listed.content))
                current (execute tools :models {:action :current} ctx)
                active (json.decode (first-text current.content))]
            (assert.is_false listed.is-error?)
            (assert.are.equal 2 (length models))
            (assert.are.equal "local/large" (. models 2 :canonical-id))
            (assert.is_true (. models 2 "default?"))
            (assert.are.equal "local/large" active.canonical-id)
            (assert.are.equal "authless" (. active :auth :status))))))))
