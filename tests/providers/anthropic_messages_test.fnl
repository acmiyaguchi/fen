;; Wire-conversion tests for the Anthropic Messages provider.

(local am (require :providers.anthropic_messages))
(local types (require :core.types))

(describe "providers.anthropic_messages.convert-tools"
  (fn []
    (it "produces flat tools with input_schema (no `function` wrapper)"
      (fn []
        (let [out (am.convert-tools
                    [{:name "ls" :description "list"
                      :parameters {:type :object :properties {}
                                   :required []}}])]
          (assert.are.equal 1 (length out))
          (assert.are.equal "ls" (. out 1 :name))
          (assert.are.equal "list" (. out 1 :description))
          (assert.is_table (. out 1 :input_schema))
          (assert.is_nil (. out 1 :function))
          (assert.is_nil (. out 1 :type)))))

    (it "returns an empty array for nil/empty input"
      (fn []
        (assert.are.equal 0 (length (am.convert-tools nil)))
        (assert.are.equal 0 (length (am.convert-tools [])))))))

(describe "providers.anthropic_messages.convert-messages"
  (fn []
    (it "does NOT prepend system prompt as a message (system is top-level)"
      (fn []
        (let [out (am.convert-messages
                    [(types.user-message "hi")] "you are a test")]
          ;; First message is the user message, not a system role.
          (assert.are.equal 1 (length out))
          (assert.are.equal :user (. out 1 :role)))))

    (it "passes a string user content through verbatim"
      (fn []
        (let [out (am.convert-messages [(types.user-message "hello")] nil)]
          (assert.are.equal "hello" (. out 1 :content)))))

    (it "converts assistant text and tool-call blocks into typed wire blocks"
      (fn []
        (let [asst (types.assistant-message
                     {:api :anthropic-messages :provider :anthropic :model "m"
                      :content [(types.text-block "answer")
                                (types.tool-call-block "toolu-1" "bash"
                                                       {:cmd "ls"})]
                      :stop-reason :tool-use})
              out (am.convert-messages [asst] nil)
              blocks (. out 1 :content)]
          (assert.are.equal 2 (length blocks))
          (assert.are.equal :text (. blocks 1 :type))
          (assert.are.equal "answer" (. blocks 1 :text))
          (assert.are.equal :tool_use (. blocks 2 :type))
          (assert.are.equal "toolu-1" (. blocks 2 :id))
          (assert.are.equal "bash" (. blocks 2 :name))
          ;; input is a parsed object (NOT a JSON-encoded string).
          (assert.are.equal "ls" (. blocks 2 :input :cmd)))))

    (it "preserves thinking blocks with their signature for multi-turn echo"
      (fn []
        (let [asst (types.assistant-message
                     {:api :anthropic-messages :provider :anthropic :model "m"
                      :content [(types.thinking-block
                                  {:thinking "..."
                                   :thinking-signature "opaque-sig"})
                                (types.text-block "answer")]
                      :stop-reason :stop})
              out (am.convert-messages [asst] nil)
              blocks (. out 1 :content)]
          (assert.are.equal :thinking (. blocks 1 :type))
          (assert.are.equal "..." (. blocks 1 :thinking))
          ;; Field name on the wire is `signature`, not `thinking-signature`.
          (assert.are.equal "opaque-sig" (. blocks 1 :signature)))))

    (it "wraps a tool-result message in a {role:user} with a tool_result block"
      (fn []
        (let [tr (types.tool-result-message
                   {:tool-call-id "toolu-1" :tool-name "bash"
                    :content [(types.text-block "stdout!")]
                    :is-error? false})
              out (am.convert-messages [tr] nil)]
          (assert.are.equal 1 (length out))
          (assert.are.equal :user (. out 1 :role))
          (let [block (. out 1 :content 1)]
            (assert.are.equal :tool_result block.type)
            (assert.are.equal "toolu-1" block.tool_use_id)
            (assert.is_nil block.is_error)
            (assert.are.equal "stdout!" (. block.content 1 :text))))))

    (it "marks is_error=true on the wire when canonical is-error? is true"
      (fn []
        (let [tr (types.tool-result-message
                   {:tool-call-id "toolu-1" :tool-name "bash"
                    :content [(types.text-block "boom")]
                    :is-error? true})
              out (am.convert-messages [tr] nil)
              block (. out 1 :content 1)]
          (assert.is_true block.is_error))))

    (it "batches consecutive tool-result messages into one user message"
      (fn []
        (let [tr1 (types.tool-result-message
                    {:tool-call-id "a" :tool-name "bash"
                     :content [(types.text-block "out-a")]
                     :is-error? false})
              tr2 (types.tool-result-message
                    {:tool-call-id "b" :tool-name "bash"
                     :content [(types.text-block "out-b")]
                     :is-error? false})
              out (am.convert-messages [tr1 tr2] nil)]
          ;; Batched into a single user message…
          (assert.are.equal 1 (length out))
          (assert.are.equal :user (. out 1 :role))
          ;; …with two tool_result blocks inside.
          (assert.are.equal 2 (length (. out 1 :content)))
          (assert.are.equal "a" (. out 1 :content 1 :tool_use_id))
          (assert.are.equal "b" (. out 1 :content 2 :tool_use_id)))))))

(describe "providers.anthropic_messages.map-stop-reason"
  (fn []
    (it "maps Anthropic stop_reason values to canonical StopReason"
      (fn []
        (let [(s _) (am.map-stop-reason :end_turn)] (assert.are.equal :stop s))
        (let [(s _) (am.map-stop-reason :max_tokens)]
          (assert.are.equal :length s))
        (let [(s _) (am.map-stop-reason :tool_use)]
          (assert.are.equal :tool-use s))
        (let [(s msg) (am.map-stop-reason :refusal)]
          (assert.are.equal :error s)
          (assert.is_truthy (string.find msg "refusal")))
        (let [(s _) (am.map-stop-reason :stop_sequence)]
          (assert.are.equal :stop s))
        (let [(s _) (am.map-stop-reason :pause_turn)]
          (assert.are.equal :stop s))))))

(describe "providers.anthropic_messages.parse-response"
  (fn []
    (it "produces a canonical AssistantMessage from a stop response"
      (fn []
        (let [resp {:content [{:type :text :text "yes"}]
                    :stop_reason :end_turn
                    :usage {:input_tokens 10 :output_tokens 5
                            :cache_read_input_tokens 0
                            :cache_creation_input_tokens 0}}
              asst (am.parse-response resp "claude-x")]
          (assert.are.equal :stop asst.stop-reason)
          (assert.are.equal :anthropic-messages asst.api)
          (assert.are.equal :anthropic asst.provider)
          (assert.are.equal "claude-x" asst.model)
          (assert.are.equal "yes" (. asst.content 1 :text))
          (assert.are.equal 10 asst.usage.input)
          (assert.are.equal 5 asst.usage.output)
          (assert.are.equal 15 asst.usage.total-tokens))))

    (it "extracts thinking blocks and preserves the signature"
      (fn []
        (let [resp {:content [{:type :thinking
                               :thinking "..."
                               :signature "sig-1"}
                              {:type :text :text "answer"}]
                    :stop_reason :end_turn
                    :usage {}}
              asst (am.parse-response resp "claude-x")
              tb (. asst.content 1)
              text (. asst.content 2)]
          (assert.are.equal :thinking tb.type)
          (assert.are.equal "..." tb.thinking)
          (assert.are.equal "sig-1" tb.thinking-signature)
          (assert.are.equal :text text.type))))

    (it "extracts tool_use blocks as canonical ToolCall (input is parsed)"
      (fn []
        (let [resp {:content [{:type :tool_use
                               :id "toolu-1"
                               :name "bash"
                               :input {:cmd "ls"}}]
                    :stop_reason :tool_use
                    :usage {}}
              asst (am.parse-response resp "claude-x")
              tc (. asst.content 1)]
          (assert.are.equal :tool-use asst.stop-reason)
          (assert.are.equal :tool-call tc.type)
          (assert.are.equal "toolu-1" tc.id)
          (assert.are.equal "bash" tc.name)
          (assert.are.equal "ls" tc.arguments.cmd))))

    (it "preserves multiple tool_use blocks in order"
      (fn []
        (let [resp {:content [{:type :tool_use
                               :id "toolu-1" :name "read"
                               :input {:path "a"}}
                              {:type :tool_use
                               :id "toolu-2" :name "grep"
                               :input {:pattern "x"}}]
                    :stop_reason :tool_use
                    :usage {}}
              asst (am.parse-response resp "claude-x")]
          (assert.are.equal 2 (length asst.content))
          (assert.are.equal "toolu-1" (. asst.content 1 :id))
          (assert.are.equal "read" (. asst.content 1 :name))
          (assert.are.equal "a" (. asst.content 1 :arguments :path))
          (assert.are.equal "toolu-2" (. asst.content 2 :id))
          (assert.are.equal "grep" (. asst.content 2 :name))
          (assert.are.equal "x" (. asst.content 2 :arguments :pattern)))))))

(describe "providers.anthropic_messages streaming reducer"
  (fn []
    (it "reduces text deltas into a canonical assistant message"
      (fn []
        (let [state {:model "claude-x"
                     :content []
                     :blocks {}
                     :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
                     :stop-reason :stop}
              events []]
          (am.process-stream-event!
            state
            {:type :message_start
             :message {:usage {:input_tokens 10 :output_tokens 0}}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_start :index 0
             :content_block {:type :text :text ""}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_delta :index 0
             :delta {:type :text_delta :text "he"}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_delta :index 0
             :delta {:type :text_delta :text "llo"}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_stop :index 0}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :message_delta
             :delta {:stop_reason :end_turn}
             :usage {:output_tokens 5}}
            #(table.insert events $1))
          (let [asst (am.finalize-stream-state state #(table.insert events $1))]
            (assert.are.equal :stop asst.stop-reason)
            (assert.are.equal "hello" (. asst.content 1 :text))
            (assert.are.equal 10 asst.usage.input)
            (assert.are.equal 5 asst.usage.output)
            (assert.are.equal :text-start (. events 1 :type))
            (assert.are.equal :text-delta (. events 2 :type))
            (assert.are.equal :text-delta (. events 3 :type))
            (assert.are.equal :text-end (. events 4 :type))
            (assert.are.equal :done (. events 5 :type))))))

    (it "buffers tool_use input_json_delta until block stop"
      (fn []
        (let [state {:model "claude-x"
                     :content []
                     :blocks {}
                     :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
                     :stop-reason :stop}
              events []
              full "{\"cmd\":\"ls\"}"]
          (am.process-stream-event!
            state
            {:type :content_block_start :index 0
             :content_block {:type :tool_use :id "toolu-1" :name "bash" :input {}}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_delta :index 0
             :delta {:type :input_json_delta :partial_json (string.sub full 1 8)}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_delta :index 0
             :delta {:type :input_json_delta :partial_json (string.sub full 9)}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_stop :index 0}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :message_delta :delta {:stop_reason :tool_use}}
            #(table.insert events $1))
          (let [asst (am.finalize-stream-state state #(table.insert events $1))
                tc (. asst.content 1)]
            (assert.are.equal :tool-use asst.stop-reason)
            (assert.are.equal :tool-call tc.type)
            (assert.are.equal "toolu-1" tc.id)
            (assert.are.equal "bash" tc.name)
            (assert.are.equal "ls" tc.arguments.cmd)
            (assert.is_nil tc.partial-json)
            (assert.are.equal :tool-call-start (. events 1 :type))
            (assert.are.equal :tool-call-delta (. events 2 :type))
            (assert.are.equal :tool-call-delta (. events 3 :type))
            (assert.are.equal :tool-call-end (. events 4 :type))
            (assert.are.equal :done (. events 5 :type))))))

    (it "preserves thinking signatures from signature deltas"
      (fn []
        (let [state {:model "claude-x"
                     :content []
                     :blocks {}
                     :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
                     :stop-reason :stop}
              events []]
          (am.process-stream-event!
            state
            {:type :content_block_start :index 0
             :content_block {:type :thinking :thinking ""}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_delta :index 0
             :delta {:type :thinking_delta :thinking "hmm"}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_delta :index 0
             :delta {:type :signature_delta :signature "sig-1"}}
            #(table.insert events $1))
          (am.process-stream-event!
            state
            {:type :content_block_stop :index 0}
            #(table.insert events $1))
          (let [asst (am.finalize-stream-state state #(table.insert events $1))
                tb (. asst.content 1)]
            (assert.are.equal :thinking tb.type)
            (assert.are.equal "hmm" tb.thinking)
            (assert.are.equal "sig-1" tb.thinking-signature)
            (assert.are.equal :thinking-start (. events 1 :type))
            (assert.are.equal :thinking-delta (. events 2 :type))
            (assert.are.equal :thinking-end (. events 3 :type))))))))

(describe "providers.anthropic_messages.build-body"
  (fn []
    (it "puts system-prompt at the top level (NOT in messages)"
      (fn []
        (let [body (am.build-body
                     "claude-x"
                     {:system-prompt "be helpful" :messages [] :tools []}
                     1024 nil)]
          ;; With prompt caching on (default), system is an array of blocks
          ;; so cache_control can attach. The text round-trips intact.
          (assert.is_table body.system)
          (assert.are.equal "be helpful" (. body.system 1 :text)))))

    (it "omits tools and tool_choice when empty/nil"
      (fn []
        (let [body (am.build-body "m" {:messages [] :tools []} 1024 nil)]
          (assert.is_nil body.tools)
          (assert.is_nil body.tool_choice))
        (let [body (am.build-body "m" {:messages []} 1024 nil)]
          (assert.is_nil body.tools)
          (assert.is_nil body.tool_choice))))

    (it "sets tool_choice as {type:auto, disable_parallel_tool_use:false} when tools are present"
      (fn []
        (let [body (am.build-body
                     "m"
                     {:messages []
                      :tools [{:name "ls" :description "list"
                               :parameters {:type :object}}]}
                     1024 nil)]
          (assert.are.equal :auto (. body.tool_choice :type))
          (assert.is_false (. body.tool_choice :disable_parallel_tool_use)))))

    (it "honors options.parallel-tool-calls=false"
      (fn []
        (let [body (am.build-body
                     "m"
                     {:messages []
                      :tools [{:name "ls" :description "list"
                               :parameters {:type :object}}]}
                     1024 {:parallel-tool-calls false})]
          (assert.is_true (. body.tool_choice :disable_parallel_tool_use)))))

    (it "enables extended thinking when :thinking-budget is given in options"
      (fn []
        (let [body (am.build-body
                     "claude-x" {:messages [] :tools []} 1024
                     {:thinking-budget 2048})]
          (assert.are.equal :enabled (. body.thinking :type))
          (assert.are.equal 2048 (. body.thinking :budget_tokens)))
        (let [body (am.build-body
                     "claude-x" {:messages [] :tools []} 1024 nil)]
          (assert.is_nil body.thinking))))))

(describe "providers.anthropic_messages.build-body cache_control"
  (fn []
    (it "marks the system block with cache_control (1h ephemeral)"
      (fn []
        (let [body (am.build-body
                     "claude-x"
                     {:system-prompt "be helpful"
                      :messages [(types.user-message "hi")]
                      :tools []}
                     1024 nil)]
          ;; System is converted to an array of blocks so cache_control can attach.
          (assert.is_table body.system)
          (assert.are.equal 1 (length body.system))
          (assert.are.equal "be helpful" (. body.system 1 :text))
          (assert.are.equal :ephemeral
                            (. body.system 1 :cache_control :type))
          (assert.are.equal :1h (. body.system 1 :cache_control :ttl)))))

    (it "marks the LAST tool with cache_control (and only the last)"
      (fn []
        (let [body (am.build-body
                     "claude-x"
                     {:messages [(types.user-message "hi")]
                      :tools [{:name "ls" :description "" :parameters {}}
                              {:name "bash" :description "" :parameters {}}]}
                     1024 nil)]
          (assert.is_nil (. body.tools 1 :cache_control))
          (assert.are.equal :ephemeral
                            (. body.tools 2 :cache_control :type)))))

    (it "marks the LAST block of the LAST message with cache_control"
      (fn []
        (let [body (am.build-body
                     "claude-x"
                     {:messages [(types.user-message "hi")]
                      :tools []}
                     1024 nil)
              last-msg (. body.messages (length body.messages))]
          ;; String user content is normalized to an array block so
          ;; cache_control can attach.
          (assert.is_table last-msg.content)
          (let [blocks last-msg.content
                last-block (. blocks (length blocks))]
            (assert.are.equal :ephemeral
                              (. last-block :cache_control :type))))))

    (it "marks tool_result block when last message is a tool-result"
      (fn []
        (let [tr (types.tool-result-message
                   {:tool-call-id "toolu-1" :tool-name "bash"
                    :content [(types.text-block "stdout")]
                    :is-error? false})
              body (am.build-body
                     "claude-x" {:messages [tr] :tools []} 1024 nil)
              last-msg (. body.messages (length body.messages))
              block (. last-msg.content 1)]
          (assert.are.equal :ephemeral
                            (. block :cache_control :type)))))

    (it "options.no-cache? suppresses all cache markers"
      (fn []
        (let [body (am.build-body
                     "claude-x"
                     {:system-prompt "x"
                      :messages [(types.user-message "y")]
                      :tools [{:name "ls" :description "" :parameters {}}]}
                     1024 {:no-cache? true})]
          ;; System stays as a plain string when caching is disabled.
          (assert.are.equal "x" body.system)
          (assert.is_nil (. body.tools 1 :cache_control))
          (let [last-msg (. body.messages (length body.messages))]
            (if (= (type last-msg.content) :string)
                (assert.are.equal "y" last-msg.content)
                (assert.is_nil (. last-msg.content 1 :cache_control)))))))))
