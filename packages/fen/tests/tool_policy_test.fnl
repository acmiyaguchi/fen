(local policy (require :fen.tool_policy))

(local TOOLS [{:name :read} {:name :bash} {:name :grep}])

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

    (it "fails closed for an unknown tool"
      (fn []
        (let [(filtered err) (policy.apply {:tools "read,write"} TOOLS)]
          (assert.is_nil filtered)
          (assert.are.equal "unknown tool in --tools: write" err))))))
