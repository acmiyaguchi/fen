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

    (it "drops thinking blocks when sending assistant content back to OpenAI"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-completions :provider :openai :model "m"
                      :content [(types.thinking-block {:thinking "...reasoning..."})
                                (types.text-block "final answer")]
                      :stop-reason :stop})
              out (oc.convert-messages [asst] nil)]
          (assert.are.equal "final answer" (. out 1 :content)))))

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
            (assert.are.equal "ls" tc.arguments.cmd)))))))

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

    (it "sets tools and tool_choice when context.tools is non-empty"
      (fn []
        (let [body (oc.build-body
                     "m"
                     {:system-prompt nil :messages []
                      :tools [{:name "ls" :description "list"
                               :parameters {:type :object}}]}
                     1024)]
          (assert.are.equal 1 (length body.tools))
          (assert.are.equal :auto body.tool_choice))))))
