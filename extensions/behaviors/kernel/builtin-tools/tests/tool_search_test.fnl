(local tool-search (require :fen.extensions.builtin_tools.tool_search))

(fn first-text [result]
  (?. result :content 1 :text))

(describe "builtin tool_search"
  (fn []
    (it "activates matching discoverable tools on the agent"
      (fn []
        (let [agent {:active-tool-names {}
                     :tools [{:name :read :exposure :always
                              :description "Read files"}
                             {:name :agent_state :owner :agent-state
                              :exposure :search
                              :description "Inspect structured runtime state"}
                             {:name :profile :owner :profiler
                              :exposure :search
                              :description "Statistical profiler"}]}
              result (tool-search.execute {:query "runtime state"} {:agent agent})]
          (assert.is_false result.is-error?)
          (assert.is_true (. agent.active-tool-names "agent_state"))
          (assert.is_nil (. agent.active-tool-names "read"))
          (assert.is_truthy (string.find (first-text result) "agent_state" 1 true)))))

    (it "ranks an exact tool name first and honors the limit"
      (fn []
        (let [agent {:active-tool-names {}
                     :tools [{:name :profile :exposure :search
                              :description "Profile runtime"}
                             {:name :agent_state :exposure :search
                              :description "Inspect profile state"}]}
              result (tool-search.execute {:query "profile" :limit 1} {:agent agent})]
          (assert.is_false result.is-error?)
          (assert.is_true (. agent.active-tool-names "profile"))
          (assert.is_nil (. agent.active-tool-names "agent_state")))))

    (it "does not activate tools that match only generic or partial terms"
      (fn []
        (let [agent {:active-tool-names {}
                     :tools [{:name :profile :exposure :search
                              :description "Profile the Lua runtime"}
                             {:name :mail :exposure :search
                              :description "Send workspace email"}]}
              result (tool-search.execute
                       {:query "tool for workspace profiling"} {:agent agent})]
          (assert.is_false result.is-error?)
          (assert.are.same {} agent.active-tool-names))))

    (it "rejects an empty query"
      (fn []
        (let [result (tool-search.execute {:query "  "} {:agent {:tools []}})]
          (assert.is_true result.is-error?)
          (assert.is_truthy (string.find (first-text result) "must not be empty" 1 true)))))))
