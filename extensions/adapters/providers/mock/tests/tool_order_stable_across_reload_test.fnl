;; Regression for #622: the tool list a provider receives has a canonical order
;; (by name), so reloading one extension never reorders it and the cached
;; prompt prefix survives. See spec/context/FINDINGS.md (#622).

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local tool-registry (require :fen.core.extensions.register.tool))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))
(local {: known-bug} (require :fen.testing))

(fn register-mock! []
  (let [p {}]
    (each [k v (pairs mock)] (tset p k v))
    (set p.name :mock)
    (register-registry.register :provider p :test)))

(fn tool [name]
  {:name name
   :label name
   :description name
   :parameters {:type :object :properties {}}
   :execute (fn []
              {:content [(types.text-block "ok")]})})

(fn register-ext! [owner name]
  (let [api (test-api.make-runtime-api owner)]
    (api.register :tool (tool name))))

(fn request-tools []
  "Build an agent from the registry (as a rebuild does), send one request,
   and return the tool names the provider received, comma-joined."
  (let [rec []
        agent (agent-mod.make-agent {:provider-name :mock
                                     :model "mock"
                                     :api-key :test
                                     :tools (tool-registry.merged [])
                                     :provider-options {:mock-script ["ok"]
                                                        :mock-record rec}})]
    (agent-mod.step agent "hi")
    (table.concat (icollect [_ t (ipairs (. rec 1 :context :tools))]
                    (tostring t.name)) ",")))

(describe "#622 single-extension reload and tool order"
          (fn []
            (before_each (fn [] (test-api.reset!) (register-mock!)))
            (after_each (fn [] (test-api.reset!)))
            (it "sends tools in canonical order regardless of registration order"
                (fn []
                  (register-ext! :ext-a :read)
                  (register-ext! :ext-b :bash)
                  (register-ext! :ext-c :grep)
                  (let [before (request-tools)]
                    (assert.are.equal "bash,grep,read" before)
                    ;; reload-extension! for ext-a, unchanged code
                    (register-registry.unregister-by-owner :ext-a)
                    (register-ext! :ext-a :read)
                    (assert.are.equal before (request-tools)))))))
