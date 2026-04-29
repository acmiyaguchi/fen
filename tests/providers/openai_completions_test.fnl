;; Wire-conversion tests for the OpenAI Chat Completions provider.
;; Mirrors the surface of pi-mono's
;; packages/ai/test/openai-completions-* tests, scoped to what we need.

(local oc (require :providers.openai_completions))
(local types (require :core.types))
(local json (require :util.json))

(describe "providers.openai_completions.convert-tools"
  (fn []
    (it "wraps canonical Tool[] in {type:function, function:{...}}"
      (fn []
        (let [out (oc.convert-tools
                    [{:name "ls" :description "list"
                      :parameters {:type :object}}])]
          (assert.are.equal 1 (length out))
          (assert.are.equal :function (. out 1 :type))
          (assert.are.equal "ls" (. out 1 :function :name))
          (assert.are.equal "list" (. out 1 :function :description)))))

    (it "returns an empty array for nil/empty input"
      (fn []
        (assert.are.equal 0 (length (oc.convert-tools nil)))
        (assert.are.equal 0 (length (oc.convert-tools [])))))))

(describe "providers.openai_completions.convert-messages"
  (fn []
    (it "prepends system prompt as a {role:system} message"
      (fn []
        (let [out (oc.convert-messages
                    [(types.user-message "hi")] "be helpful")]
          (assert.are.equal :system (. out 1 :role))
          (assert.are.equal "be helpful" (. out 1 :content))
          (assert.are.equal :user (. out 2 :role)))))

    (it "omits system message when system-prompt is nil/empty"
      (fn []
        (let [out (oc.convert-messages [(types.user-message "hi")] nil)]
          (assert.are.equal :user (. out 1 :role)))
        (let [out (oc.convert-messages [(types.user-message "hi")] "")]
          (assert.are.equal :user (. out 1 :role)))))

    (it "concats text blocks of an assistant message into content string"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-completions :provider :openai :model "m"
                      :content [(types.text-block "hello, ")
                                (types.text-block "world")]
                      :stop-reason :stop})
              out (oc.convert-messages [asst] nil)]
          (assert.are.equal "hello, world" (. out 1 :content)))))

    (it "drops unsigned thinking blocks when sending assistant content back to OpenAI"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-completions :provider :openai :model "m"
                      :content [(types.thinking-block {:thinking "...reasoning..."})
                                (types.text-block "final answer")]
                      :stop-reason :stop})
              out (oc.convert-messages [asst] nil)]
          (assert.are.equal "final answer" (. out 1 :content))
          (assert.is_nil (. out 1 :reasoning_content)))))

    (it "echoes signed thinking blocks under their OpenAI-compatible reasoning field"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-completions :provider :openai :model "m"
                      :content [(types.thinking-block
                                  {:thinking "internal reasoning"
                                   :thinking-signature :reasoning_content})
                                (types.text-block "final answer")]
                      :stop-reason :stop})
              out (oc.convert-messages [asst] nil {:thinkingFormat :zai})]
          (assert.are.equal "final answer" (. out 1 :content))
          (assert.are.equal "internal reasoning" (. out 1 :reasoning_content)))))

    (it "lifts tool-call blocks into the tool_calls array, JSON-encoding arguments"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-completions :provider :openai :model "m"
                      :content [(types.tool-call-block "id-1" "bash" {:cmd "ls"})]
                      :stop-reason :tool-use})
              out (oc.convert-messages [asst] nil)
              tc (. out 1 :tool_calls 1)]
          (assert.are.equal "id-1" tc.id)
          (assert.are.equal :function tc.type)
          (assert.are.equal "bash" tc.function.name)
          ;; arguments must be a JSON-encoded string, not a table
          (assert.is_string tc.function.arguments)
          (let [parsed (json.decode tc.function.arguments)]
            (assert.are.equal "ls" parsed.cmd)))))

    (it "converts a tool-result message to {role:tool, tool_call_id, content}"
      (fn []
        (let [tr (types.tool-result-message
                   {:tool-call-id "id-1" :tool-name "bash"
                    :content [(types.text-block "stdout!")]
                    :is-error? false})
              out (oc.convert-messages [tr] nil)]
          (assert.are.equal :tool (. out 1 :role))
          (assert.are.equal "id-1" (. out 1 :tool_call_id))
          (assert.are.equal "stdout!" (. out 1 :content)))))))

(describe "providers.openai_completions.map-stop-reason"
  (fn []
    (it "maps OpenAI finish_reason values to canonical StopReason"
      (fn []
        (let [(s _) (oc.map-stop-reason :stop)] (assert.are.equal :stop s))
        (let [(s _) (oc.map-stop-reason :length)] (assert.are.equal :length s))
        (let [(s _) (oc.map-stop-reason :tool_calls)] (assert.are.equal :tool-use s))
        (let [(s _) (oc.map-stop-reason :function_call)] (assert.are.equal :tool-use s))
        (let [(s msg) (oc.map-stop-reason :content_filter)]
          (assert.are.equal :error s)
          (assert.is_truthy (string.find msg "content_filter")))
        (let [(s _) (oc.map-stop-reason nil)] (assert.are.equal :stop s))))))

(describe "providers.openai_completions.parse-response"
  (fn []
    (it "produces a canonical AssistantMessage from a stop response"
      (fn []
        (let [resp {:choices [{:message {:role :assistant :content "yes"}
                               :finish_reason :stop}]
                    :usage {:prompt_tokens 10 :completion_tokens 5
                            :total_tokens 15}}
              asst (oc.parse-response resp "gpt-4o-mini")]
          (assert.are.equal :assistant asst.role)
          (assert.are.equal :stop asst.stop-reason)
          (assert.are.equal :openai-completions asst.api)
          (assert.are.equal :openai asst.provider)
          (assert.are.equal "gpt-4o-mini" asst.model)
          (assert.are.equal "yes" (. asst.content 1 :text))
          (assert.are.equal 10 asst.usage.input)
          (assert.are.equal 5 asst.usage.output))))

    (it "extracts reasoning_content as a signed thinking block before text"
      (fn []
        (let [resp {:choices [{:message {:role :assistant
                                          :reasoning_content "think first"
                                          :content "final"}
                               :finish_reason :stop}]
                    :usage {:prompt_tokens 0 :completion_tokens 0 :total_tokens 0}}
              asst (oc.parse-response resp "m")
              thinking (. asst.content 1)
              text (. asst.content 2)]
          (assert.are.equal :thinking thinking.type)
          (assert.are.equal "think first" thinking.thinking)
          (assert.are.equal :reasoning_content thinking.thinking-signature)
          (assert.are.equal :text text.type)
          (assert.are.equal "final" text.text))))

    (it "extracts reasoning and reasoning_text fallback fields"
      (fn []
        (let [resp1 {:choices [{:message {:role :assistant
                                           :reasoning "think via reasoning"
                                           :content "final"}
                                :finish_reason :stop}]}
              resp2 {:choices [{:message {:role :assistant
                                           :reasoning_text "think via reasoning_text"
                                           :content "final"}
                                :finish_reason :stop}]}
              asst1 (oc.parse-response resp1 "m")
              asst2 (oc.parse-response resp2 "m")]
          (assert.are.equal "think via reasoning" (. asst1.content 1 :thinking))
          (assert.are.equal :reasoning (. asst1.content 1 :thinking-signature))
          (assert.are.equal "think via reasoning_text" (. asst2.content 1 :thinking))
          (assert.are.equal :reasoning_text (. asst2.content 1 :thinking-signature)))))

    (it "uses the first non-empty reasoning field to avoid duplicates"
      (fn []
        (let [resp {:choices [{:message {:role :assistant
                                          :reasoning_content ""
                                          :reasoning "first non-empty"
                                          :reasoning_text "duplicate"
                                          :content "final"}
                               :finish_reason :stop}]}
              asst (oc.parse-response resp "m")]
          (assert.are.equal 2 (length asst.content))
          (assert.are.equal "first non-empty" (. asst.content 1 :thinking))
          (assert.are.equal :reasoning (. asst.content 1 :thinking-signature)))))

    (it "produces tool-call blocks when tool_calls are present"
      (fn []
        (let [resp {:choices
                    [{:message
                      {:role :assistant
                       :content nil
                       :tool_calls
                       [{:id "id-1"
                         :type :function
                         :function {:name "bash"
                                    :arguments "{\"cmd\":\"ls\"}"}}]}
                      :finish_reason :tool_calls}]
                    :usage {:prompt_tokens 0 :completion_tokens 0 :total_tokens 0}}
              asst (oc.parse-response resp "m")]
          (assert.are.equal :tool-use asst.stop-reason)
          (let [tc (. asst.content 1)]
            (assert.are.equal :tool-call tc.type)
            (assert.are.equal "id-1" tc.id)
            (assert.are.equal "bash" tc.name)
            ;; arguments must be a parsed table (JSON string was decoded).
            (assert.are.equal "ls" tc.arguments.cmd)))))

    (it "preserves multiple tool_calls in order"
      (fn []
        (let [resp {:choices
                    [{:message
                      {:role :assistant
                       :content nil
                       :tool_calls
                       [{:id "id-1" :type :function
                         :function {:name "read" :arguments "{\"path\":\"a\"}"}}
                        {:id "id-2" :type :function
                         :function {:name "grep" :arguments "{\"pattern\":\"x\"}"}}]}
                      :finish_reason :tool_calls}]}
              asst (oc.parse-response resp "m")]
          (assert.are.equal 2 (length asst.content))
          (assert.are.equal "id-1" (. asst.content 1 :id))
          (assert.are.equal "read" (. asst.content 1 :name))
          (assert.are.equal "a" (. asst.content 1 :arguments :path))
          (assert.are.equal "id-2" (. asst.content 2 :id))
          (assert.are.equal "grep" (. asst.content 2 :name))
          (assert.are.equal "x" (. asst.content 2 :arguments :pattern)))))

    (it "accepts tool-call arguments returned as a parsed object (Ollama quirk)"
      (fn []
        (let [resp {:choices
                    [{:message
                      {:role :assistant
                       :content nil
                       :tool_calls
                       [{:id "id-2"
                         :type :function
                         :function {:name "bash"
                                    ;; Already-parsed object, not a JSON string.
                                    :arguments {:cmd "pwd"}}}]}
                      :finish_reason :tool_calls}]
                    :usage {:prompt_tokens 0 :completion_tokens 0 :total_tokens 0}}
              asst (oc.parse-response resp "m")
              tc (. asst.content 1)]
          (assert.are.equal :tool-call tc.type)
          (assert.are.equal "pwd" tc.arguments.cmd))))

    (it "falls back to {} when the arguments string is malformed JSON"
      (fn []
        (let [resp {:choices
                    [{:message
                      {:role :assistant
                       :content nil
                       :tool_calls
                       [{:id "id-3"
                         :type :function
                         :function {:name "bash"
                                    :arguments "{not json"}}]}
                      :finish_reason :tool_calls}]
                    :usage {:prompt_tokens 0 :completion_tokens 0 :total_tokens 0}}
              asst (oc.parse-response resp "m")
              tc (. asst.content 1)]
          (assert.is_table tc.arguments)
          (assert.is_nil (next tc.arguments)))))))

(describe "providers.openai_completions streaming reducer"
  (fn []
    (it "reduces text deltas into a canonical assistant message"
      (fn []
        (let [state {:model "m"
                     :content []
                     :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
                     :stop-reason :stop}
              events []]
          (oc.process-stream-chunk!
            state
            {:choices [{:delta {:content "he"}}]}
            #(table.insert events $1))
          (oc.process-stream-chunk!
            state
            {:choices [{:delta {:content "llo"} :finish_reason :stop}]
             :usage {:prompt_tokens 3 :completion_tokens 2 :total_tokens 5}}
            #(table.insert events $1))
          (let [asst (oc.finalize-stream-state state #(table.insert events $1))]
            (assert.are.equal :stop asst.stop-reason)
            (assert.are.equal "hello" (. asst.content 1 :text))
            (assert.are.equal 3 asst.usage.input)
            (assert.are.equal :text-start (. events 1 :type))
            (assert.are.equal :text-delta (. events 2 :type))
            (assert.are.equal :text-delta (. events 3 :type))
            (assert.are.equal :text-end (. events 4 :type))
            (assert.are.equal :done (. events 5 :type))))))

    (it "buffers streamed tool-call arguments until finalization"
      (fn []
        (let [state {:model "m"
                     :content []
                     :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
                     :stop-reason :stop}
              events []]
          (oc.process-stream-chunk!
            state
            {:choices
             [{:delta
               {:tool_calls
                [{:index 0
                  :id "call-1"
                  :function {:name "bash"
                             :arguments (string.sub "{\"cmd\":\"ls\"}" 1 8)}}]}}]}
            #(table.insert events $1))
          (oc.process-stream-chunk!
            state
            {:choices
             [{:delta
               {:tool_calls
                [{:index 0
                  :function {:arguments (string.sub "{\"cmd\":\"ls\"}" 9)}}]}
               :finish_reason :tool_calls}]}
            #(table.insert events $1))
          (let [asst (oc.finalize-stream-state state #(table.insert events $1))
                tc (. asst.content 1)]
            (assert.are.equal :tool-use asst.stop-reason)
            (assert.are.equal :tool-call tc.type)
            (assert.are.equal "call-1" tc.id)
            (assert.are.equal "bash" tc.name)
            (assert.are.equal "ls" tc.arguments.cmd)
            (assert.is_nil tc.partial-args)
            (assert.is_nil tc.stream-index)
            (assert.are.equal :tool-call-start (. events 1 :type))
            (assert.are.equal :tool-call-delta (. events 2 :type))
            (assert.are.equal :tool-call-delta (. events 3 :type))
            (assert.are.equal :tool-call-end (. events 4 :type))
            (assert.are.equal :done (. events 5 :type))))))))

(describe "providers.openai_completions.build-url"
  (fn []
    (it "appends /chat/completions to a v1-root base URL"
      (fn []
        (assert.are.equal "http://localhost:11434/v1/chat/completions"
                          (oc.build-url "http://localhost:11434/v1"))
        (assert.are.equal "https://api.openai.com/v1/chat/completions"
                          (oc.build-url "https://api.openai.com/v1"))))

    (it "respects a fully-qualified completions URL (legacy callers)"
      (fn []
        (assert.are.equal "https://api.openai.com/v1/chat/completions"
                          (oc.build-url "https://api.openai.com/v1/chat/completions"))))))

(describe "providers.openai_completions.build-body"
  (fn []
    (it "omits tools and tool_choice when context.tools is nil or empty"
      (fn []
        (let [body (oc.build-body "gpt-4o-mini"
                                   {:system-prompt nil :messages [] :tools []}
                                   64)]
          (assert.is_nil body.tools)
          (assert.is_nil body.tool_choice)
          (assert.are.equal 64 body.max_completion_tokens)
          (assert.are.equal "gpt-4o-mini" body.model))
        (let [body (oc.build-body "m" {:system-prompt nil :messages []} 1024)]
          (assert.is_nil body.tools)
          (assert.is_nil body.tool_choice))))

    (it "sets tools, tool_choice, and parallel_tool_calls when context.tools is non-empty"
      (fn []
        (let [body (oc.build-body
                     "m"
                     {:system-prompt nil :messages []
                      :tools [{:name "ls" :description "list"
                               :parameters {:type :object}}]}
                     1024)]
          (assert.are.equal 1 (length body.tools))
          (assert.are.equal :auto body.tool_choice)
          (assert.is_true body.parallel_tool_calls))))

    (it "honors options.parallel-tool-calls=false"
      (fn []
        (let [body (oc.build-body
                     "m"
                     {:system-prompt nil :messages []
                      :tools [{:name "ls" :description "list"
                               :parameters {:type :object}}]}
                     1024 nil {:parallel-tool-calls false})]
          (assert.is_false body.parallel_tool_calls))))

    (it "uses max_completion_tokens by default"
      (fn []
        (let [body (oc.build-body "m" {:system-prompt nil :messages []} 256)]
          (assert.are.equal 256 body.max_completion_tokens)
          (assert.is_nil body.max_tokens))))

    (it "honors compat.maxTokensField when provided (Ollama needs max_tokens)"
      (fn []
        (let [body (oc.build-body
                     "m" {:system-prompt nil :messages []} 256
                     {:maxTokensField :max_tokens})]
          (assert.are.equal 256 body.max_tokens)
          (assert.is_nil body.max_completion_tokens))))

    (it "enables GLM/Z.ai style thinking when compat.thinkingFormat is zai"
      (fn []
        (let [body (oc.build-body
                     "m" {:system-prompt nil :messages []} 256
                     {:thinkingFormat :zai})]
          (assert.are.equal true body.enable_thinking))))

    (it "allows compat.enableThinking=false to disable thinkingFormat knobs"
      (fn []
        (let [body (oc.build-body
                     "m" {:system-prompt nil :messages []} 256
                     {:thinkingFormat :zai :enableThinking false})]
          (assert.are.equal false body.enable_thinking))))

    (it "ignores unknown compat keys"
      (fn []
        (let [body (oc.build-body
                     "m" {:system-prompt nil :messages []} 256
                     {:supportsDeveloperRole false})]
          ;; Default field still wins; the extra knob is a no-op today.
          (assert.are.equal 256 body.max_completion_tokens))))))
