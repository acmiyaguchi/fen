(local policy (require :fen.tool_policy))
(local interactive (require :fen.interactive))
(local ext-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))

(local TOOLS [{:name :read} {:name :bash} {:name :grep}])

(after_each (fn [] (ext-api.reset!)))

(describe "fen.tool_policy"
  (fn []
    (it "leaves the registry unchanged without a policy"
      (fn []
        (assert.are.same TOOLS (policy.apply {} TOOLS))))

    (it "disables every tool"
      (fn []
        (assert.are.same [] (policy.apply {:no-tools? true} TOOLS))))

    (it "preserves registry order while enforcing an allowlist"
      (fn []
        (assert.are.same [{:name :read} {:name :grep}]
                         (policy.apply {:tools "grep, read,grep"} TOOLS))))

    (it "fails closed for an empty allowlist"
      (fn []
        (let [(filtered err) (policy.apply {:tools " , "} TOOLS)]
          (assert.is_nil filtered)
          (assert.are.equal "--tools must name at least one tool" err))))

    (it "honors and exposes a name registered by an extension"
      (fn []
        (ext-api.reset!)
        (let [api (ext-api.make-runtime-api :profile-extension)]
          (api.register :tool {:name :profile :exposure :search})
          (let [(filtered err)
                (policy.apply {:tools "profile"}
                              (tool-registry.merged [{:name :read}]))
                agent (interactive.make-agent-from-opts
                        (fn [_] {:provider-name :test :model "test-model"})
                        {:tools "profile" :pinned-tools []}
                        (fn [_] nil)
                        {})]
            (assert.is_nil err)
            (assert.are.equal 1 (length filtered))
            (assert.are.equal :profile (. (. filtered 1) :name))
            (assert.is_true (. agent.active-tool-names "profile"))))))

    (it "fails closed and lists every unknown tool"
      (fn []
        (let [(filtered err) (policy.apply {:tools "read,write,nope"} TOOLS)]
          (assert.is_nil filtered)
          (assert.are.equal "unknown tool name(s) in --tools: write, nope" err))))))
