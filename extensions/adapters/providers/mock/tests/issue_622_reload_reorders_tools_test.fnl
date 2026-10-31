;; Known-bug probe for #622: reloading one extension runs
;; unregister-by-owner and re-registers, which appends that owner's tools at
;; the end of the registry. The rebuilt agent sends the same tools in a new
;; order, and since tools precede system and messages the cached prefix is
;; lost. The reload is reproduced with the two registry calls
;; `load-module-spec!` makes. See spec/context/FINDINGS.md (#622).

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
            (it "moves the reloaded owner's tools to the end"
                (fn []
                  (known-bug 622
                             (fn []
                               (register-ext! :ext-a :read)
                               (register-ext! :ext-b :bash)
                               (register-ext! :ext-c :grep)
                               (let [before (request-tools)]
                                 ;; reload-extension! for ext-a, unchanged code
                                 (register-registry.unregister-by-owner :ext-a)
                                 (register-ext! :ext-a :read)
                                 (let [after (request-tools)]
                                   (and (= "read,bash,grep" before)
                                        (= "bash,grep,read" after))))))))))
