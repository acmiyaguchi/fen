(local prompt (require :fen.extensions.default_prompt))

(local search-tools
  [{:name :tool_search :exposure :search :snippet "Find and activate specialized tools"}
   {:name :bash :exposure :always :snippet "Run a shell command"}
   {:name :read :snippet "Read files"}
   {:name :todo_write :exposure :search :snippet "Update the structured todo list"}
   {:name :subagent :exposure :search :snippet "Delegate to a child agent"}
   {:name :plan :exposure :search :description "Draft a plan"}])

(describe "default_prompt.available-tools-section"
  (fn []
    (it "lists search-gated tools with their snippets"
      (fn []
        (let [section (prompt.available-tools-section search-tools)]
          (assert.is_truthy section)
          (assert.is_truthy (string.find section "activate with tool_search" 1 true))
          (assert.is_truthy (string.find section "todo_write — Update the structured todo list" 1 true))
          (assert.is_truthy (string.find section "subagent — Delegate to a child agent" 1 true))
          (assert.is_truthy (string.find section "plan — Draft a plan" 1 true)))))

    (it "omits always-visible tools and tool_search itself"
      (fn []
        (let [section (prompt.available-tools-section search-tools)]
          (assert.is_nil (string.find section "\n- bash" 1 true))
          (assert.is_nil (string.find section "\n- read" 1 true))
          (assert.is_nil (string.find section "\n- tool_search" 1 true)))))

    (it "returns nil when tool_search is not available"
      (fn []
        (assert.is_nil
          (prompt.available-tools-section
            [{:name :bash :exposure :always}]))))

    (it "returns nil when no search-gated tools exist"
      (fn []
        (assert.is_nil
          (prompt.available-tools-section
            [{:name :tool_search :exposure :search}
             {:name :bash :exposure :always}]))))))
