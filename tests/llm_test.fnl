;; Shape tests for core.llm.build-request. Run via `make test`.
;; The busted helper at tests/busted-helper.lua has already installed the
;; Fennel loader and pointed package.path at src/.

(local llm (require :core.llm))

(describe "core.llm.build-request"
  (fn []
    (it "passes through model and snake-cases max_tokens"
      (fn []
        (let [req (llm.build-request
                    {:model :gpt-4o-mini
                     :messages [{:role :user :content :hi}]
                     :max-tokens 64})]
          (assert.are.equal :gpt-4o-mini req.model)
          (assert.are.equal 64 req.max_tokens)
          (assert.are.equal 1 (length req.messages))
          (assert.is_nil req.tools)
          (assert.is_nil req.tool_choice))))

    (it "defaults max_tokens when caller omits it"
      (fn []
        (let [req (llm.build-request
                    {:model :gpt-4o-mini :messages []})]
          (assert.are.equal 1024 req.max_tokens))))

    (it "sets tools and tool_choice when tools are present"
      (fn []
        (let [req (llm.build-request
                    {:model :gpt-4o-mini
                     :messages []
                     :tools [{:type :function
                              :function {:name :ls
                                         :description "list"
                                         :parameters {:type :object}}}]})]
          (assert.are.equal 1 (length req.tools))
          (assert.are.equal :auto req.tool_choice))))

    ;; Regression mirroring pi-mono/packages/ai/test/openai-completions-empty-tools.test.ts.
    ;; OpenAI-compatible backends (DashScope, etc.) reject `tools: []` with HTTP 400.
    (it "omits tools and tool_choice when tools is an empty array"
      (fn []
        (let [req (llm.build-request
                    {:model :gpt-4o-mini :messages [] :tools []})]
          (assert.is_nil req.tools)
          (assert.is_nil req.tool_choice))))))
