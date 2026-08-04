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

    (it "preserves registry order while enforcing a denylist"
      (fn []
        (assert.are.same [{:name :read} {:name :grep}]
                         (policy.apply {:denied-tools "bash, bash"} TOOLS))))

    (it "fails closed and lists every unknown denied tool"
      (fn []
        (let [(filtered err) (policy.apply {:denied-tools "write,nope"} TOOLS)]
          (assert.is_nil filtered)
          (assert.are.equal "unknown tool name(s) in --denied-tools: write, nope" err))))

    (it "reports mutually exclusive tool restriction flags"
      (fn []
        (assert.are.equal "--tools and --denied-tools cannot be combined"
                          (policy.conflict-error {:tools "read" :denied-tools "bash"}))
        (assert.are.equal "--no-tools and --denied-tools cannot be combined"
                          (policy.conflict-error {:no-tools? true :denied-tools "bash"}))))

    (it "describes active and restricted tools for a denylist"
      (fn []
        (let [(info err) (policy.restriction-info {:denied-tools "bash"} TOOLS)]
          (assert.is_nil err)
          (assert.are.same ["read" "grep"] info.active-names)
          (assert.are.same {:bash true} info.restricted-names)
          (assert.are.equal 3 info.total)
          (assert.are.equal "--denied-tools" info.flag))))

    (it "describes active and restricted tools for an allowlist"
      (fn []
        (let [(info err) (policy.restriction-info {:tools "read"} TOOLS)]
          (assert.is_nil err)
          (assert.are.same ["read"] info.active-names)
          (assert.are.same {:bash true :grep true} info.restricted-names)
          (assert.are.equal 3 info.total)
          (assert.are.equal "--tools" info.flag))))

    (it "describes --no-tools as restricting every registered tool"
      (fn []
        (let [(info err) (policy.restriction-info {:no-tools? true} TOOLS)]
          (assert.is_nil err)
          (assert.are.same [] info.active-names)
          (assert.are.equal 3 info.total)
          (assert.are.equal "--no-tools" info.flag)
          (assert.is_true info.restricted-names.read)
          (assert.is_true info.restricted-names.bash)
          (assert.is_true info.restricted-names.grep))))

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
