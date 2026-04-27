;; Wire-conversion and streaming-reducer tests for the OpenAI Responses
;; provider. Fixture event sequences mirror the shapes produced by
;; api.openai.com/v1/responses; the same shapes (with a few aliases) feed
;; the Codex Responses provider added in phase 3.

(local shared (require :providers.openai_responses_shared))
(local responses (require :providers.openai_responses))
(local types (require :core.types))
(local json (require :util.json))
(local sse (require :util.sse))

(fn run-events [events emit]
  (let [state (shared.new-stream-state "gpt-5.5")]
    (each [_ ev (ipairs events)]
      (shared.process-event! state ev emit))
    (shared.finalize-stream-state state :openai-responses :openai emit)))

(fn run-sse [raw emit]
  "Drive a fixture SSE string through the real parser + reducer."
  (let [state (shared.new-stream-state "gpt-5.5")
        parser (sse.new-parser
                 (fn [ev]
                   (when (and (not= ev.data nil)
                              (not= ev.data "")
                              (not= ev.data "[DONE]"))
                     (let [(ok? decoded) (pcall json.decode ev.data)]
                       (when ok?
                         (shared.process-event! state decoded emit))))))]
    (parser.feed raw)
    (parser.finish)
    (shared.finalize-stream-state state :openai-responses :openai emit)))

(describe "providers.openai_responses_shared.convert-tools"
  (fn []
    (it "produces flat {type:function, name, description, parameters, strict} entries"
      (fn []
        (let [out (shared.convert-tools
                    [{:name "ls" :description "list"
                      :parameters {:type :object}}])]
          (assert.are.equal 1 (length out))
          (assert.are.equal :function (. out 1 :type))
          (assert.are.equal "ls" (. out 1 :name))
          (assert.are.equal "list" (. out 1 :description))
          ;; No `function: {...}` wrapper unlike Chat Completions.
          (assert.is_nil (. out 1 :function)))))))

(describe "providers.openai_responses_shared.convert-messages"
  (fn []
    (it "wraps a user string in [{type:input_text, text}]"
      (fn []
        (let [out (shared.convert-messages [(types.user-message "hi there")])]
          (assert.are.equal 1 (length out))
          (assert.are.equal :user (. out 1 :role))
          (assert.are.equal :input_text (. out 1 :content 1 :type))
          (assert.are.equal "hi there" (. out 1 :content 1 :text)))))

    (it "emits assistant text as a {type:message, role:assistant} item"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.text-block "answer")]
                      :stop-reason :stop})
              out (shared.convert-messages [asst])]
          (assert.are.equal :message (. out 1 :type))
          (assert.are.equal :assistant (. out 1 :role))
          (assert.are.equal :output_text (. out 1 :content 1 :type))
          (assert.are.equal "answer" (. out 1 :content 1 :text)))))

    (it "skips assistant thinking blocks without a serialized reasoning signature"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.thinking-block {:thinking "thoughts"})
                                (types.text-block "answer")]
                      :stop-reason :stop})
              out (shared.convert-messages [asst])]
          ;; Only the message item; the thinking block was dropped.
          (assert.are.equal 1 (length out))
          (assert.are.equal :message (. out 1 :type)))))

    (it "round-trips a thinking block when its signature is a serialized reasoning item"
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_1"
                              :summary [{:type :summary_text :text "thoughts"}]}
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.thinking-block
                                  {:thinking "thoughts"
                                   :thinking-signature (json.encode reasoning-item)})
                                (types.text-block "answer")]
                      :stop-reason :stop})
              out (shared.convert-messages [asst])]
          (assert.are.equal 2 (length out))
          (assert.are.equal :reasoning (. out 1 :type))
          (assert.are.equal "rs_1" (. out 1 :id))
          (assert.are.equal :message (. out 2 :type)))))

    (it "splits compound tool-call ids into call_id and item id on the wire"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.tool-call-block
                                  "call_abc|fc_xyz" "bash" {:cmd "ls"})]
                      :stop-reason :tool-use})
              out (shared.convert-messages [asst])]
          (assert.are.equal :function_call (. out 1 :type))
          (assert.are.equal "call_abc" (. out 1 :call_id))
          (assert.are.equal "fc_xyz" (. out 1 :id))
          (assert.are.equal "bash" (. out 1 :name))
          ;; Arguments must be a JSON-encoded string per the API.
          (assert.is_string (. out 1 :arguments))
          (let [parsed (json.decode (. out 1 :arguments))]
            (assert.are.equal "ls" parsed.cmd)))))

    (it "converts a tool-result message to {type:function_call_output}"
      (fn []
        (let [tr (types.tool-result-message
                   {:tool-call-id "call_abc|fc_xyz" :tool-name "bash"
                    :content [(types.text-block "stdout!")]})
              out (shared.convert-messages [tr])]
          (assert.are.equal :function_call_output (. out 1 :type))
          (assert.are.equal "call_abc" (. out 1 :call_id))
          (assert.are.equal "stdout!" (. out 1 :output)))))))

(describe "providers.openai_responses_shared.map-stop-reason"
  (fn []
    (it "maps Responses status to canonical StopReason"
      (fn []
        (let [(s _) (shared.map-stop-reason :completed)] (assert.are.equal :stop s))
        (let [(s _) (shared.map-stop-reason :incomplete)] (assert.are.equal :length s))
        (let [(s _) (shared.map-stop-reason :failed)] (assert.are.equal :error s))
        (let [(s _) (shared.map-stop-reason :cancelled)] (assert.are.equal :error s))
        (let [(s _) (shared.map-stop-reason nil)] (assert.are.equal :stop s))))))

(describe "providers.openai_responses_shared streaming reducer"
  (fn []
    (it "reduces text deltas into a canonical assistant message"
      (fn []
        (let [events
              [{:type :response.output_item.added
                :item {:type :message :id "msg_1" :role :assistant :content []}}
               {:type :response.content_part.added
                :part {:type :output_text :text ""}}
               {:type :response.output_text.delta :delta "he"}
               {:type :response.output_text.delta :delta "llo"}
               {:type :response.output_item.done
                :item {:type :message :id "msg_1" :role :assistant
                       :content [{:type :output_text :text "hello"}]}}
               {:type :response.completed
                :response {:id "resp_1" :status :completed
                           :usage {:input_tokens 5 :output_tokens 2 :total_tokens 7}}}]
              seen []
              asst (run-events events #(table.insert seen $1))]
          (assert.are.equal :stop asst.stop-reason)
          (assert.are.equal "hello" (. asst.content 1 :text))
          (assert.are.equal 5 asst.usage.input)
          (assert.are.equal 2 asst.usage.output)
          (assert.are.equal :text-start (. seen 1 :type))
          (assert.are.equal :text-delta (. seen 2 :type))
          (assert.are.equal "he" (. seen 2 :delta))
          (assert.are.equal :text-delta (. seen 3 :type))
          (assert.are.equal "llo" (. seen 3 :delta))
          (assert.are.equal :text-end (. seen 4 :type))
          (assert.are.equal :done (. seen 5 :type)))))

    (it "subtracts cached_tokens from input_tokens"
      (fn []
        (let [events
              [{:type :response.output_item.added
                :item {:type :message :id "msg_1" :role :assistant :content []}}
               {:type :response.output_text.delta :delta "ok"}
               {:type :response.output_item.done
                :item {:type :message :id "msg_1" :role :assistant
                       :content [{:type :output_text :text "ok"}]}}
               {:type :response.completed
                :response {:status :completed
                           :usage {:input_tokens 100 :output_tokens 5 :total_tokens 105
                                   :input_tokens_details {:cached_tokens 80}}}}]
              asst (run-events events nil)]
          ;; OpenAI includes cached tokens in input_tokens — the reducer
          ;; subtracts so :input is the non-cached count.
          (assert.are.equal 20 asst.usage.input)
          (assert.are.equal 80 asst.usage.cache-read)
          (assert.are.equal 5 asst.usage.output))))

    (it "buffers streamed tool-call arguments and parses on done"
      (fn []
        (let [events
              [{:type :response.output_item.added
                :item {:type :function_call :call_id "call_1" :id "fc_1"
                       :name "bash" :arguments ""}}
               {:type :response.function_call_arguments.delta :delta "{\"cmd"}
               {:type :response.function_call_arguments.delta :delta "\":\"ls"}
               {:type :response.function_call_arguments.delta :delta "\"}"}
               {:type :response.function_call_arguments.done
                :arguments "{\"cmd\":\"ls\"}"}
               {:type :response.output_item.done
                :item {:type :function_call :call_id "call_1" :id "fc_1"
                       :name "bash" :arguments "{\"cmd\":\"ls\"}"}}
               {:type :response.completed
                :response {:status :completed
                           :usage {:input_tokens 0 :output_tokens 0 :total_tokens 0}}}]
              seen []
              asst (run-events events #(table.insert seen $1))
              tc (. asst.content 1)]
          (assert.are.equal :tool-use asst.stop-reason)
          (assert.are.equal :tool-call tc.type)
          (assert.are.equal "call_1|fc_1" tc.id)
          (assert.are.equal "bash" tc.name)
          (assert.are.equal "ls" tc.arguments.cmd)
          (assert.is_nil tc.partial-json)
          (assert.are.equal :tool-call-start (. seen 1 :type))
          (assert.are.equal :tool-call-delta (. seen 2 :type))
          (assert.are.equal :tool-call-delta (. seen 3 :type))
          (assert.are.equal :tool-call-delta (. seen 4 :type))
          (assert.are.equal :tool-call-end (. seen 5 :type))
          (assert.are.equal :done (. seen 6 :type)))))

    (it "captures reasoning summary deltas as canonical thinking"
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_1"
                              :summary [{:type :summary_text :text "first thought"}]}
              events
              [{:type :response.output_item.added
                :item {:type :reasoning :id "rs_1"}}
               {:type :response.reasoning_summary_part.added
                :part {:type :summary_text :text ""}}
               {:type :response.reasoning_summary_text.delta :delta "first "}
               {:type :response.reasoning_summary_text.delta :delta "thought"}
               {:type :response.output_item.done :item reasoning-item}
               {:type :response.output_item.added
                :item {:type :message :id "msg_1" :role :assistant :content []}}
               {:type :response.output_text.delta :delta "answer"}
               {:type :response.output_item.done
                :item {:type :message :id "msg_1" :role :assistant
                       :content [{:type :output_text :text "answer"}]}}
               {:type :response.completed
                :response {:status :completed
                           :usage {:input_tokens 0 :output_tokens 0 :total_tokens 0}}}]
              asst (run-events events nil)
              thinking (. asst.content 1)
              text (. asst.content 2)]
          (assert.are.equal :thinking thinking.type)
          (assert.are.equal "first thought" thinking.thinking)
          ;; Signature is the JSON-encoded reasoning item, so multi-turn
          ;; replay can echo it back.
          (assert.is_string thinking.thinking-signature)
          (let [decoded (json.decode thinking.thinking-signature)]
            (assert.are.equal "rs_1" decoded.id))
          (assert.are.equal :text text.type)
          (assert.are.equal "answer" text.text))))

    (it "marks stop-reason :error on response.failed"
      (fn []
        (let [events
              [{:type :response.failed
                :response {:error {:code "rate_limited"
                                   :message "slow down"}}}]
              asst (run-events events nil)]
          (assert.are.equal :error asst.stop-reason)
          (assert.is_string asst.error-message)
          (assert.is_truthy (string.find asst.error-message "rate_limited" 1 true))
          (assert.is_truthy (string.find asst.error-message "slow down" 1 true)))))

    (it "marks stop-reason :error on top-level error event"
      (fn []
        (let [events
              [{:type :error :code "server_error" :message "boom"}]
              asst (run-events events nil)]
          (assert.are.equal :error asst.stop-reason)
          (assert.is_string asst.error-message)
          (assert.is_truthy (string.find asst.error-message "server_error" 1 true)))))))

(describe "providers.openai_responses_shared.clamp-reasoning-effort"
  (fn []
    (it "clamps :minimal to :low on gpt-5.2/5.3/5.4/5.5"
      (fn []
        (assert.are.equal :low (shared.clamp-reasoning-effort "gpt-5.5" :minimal))
        (assert.are.equal :low (shared.clamp-reasoning-effort "gpt-5.2" :minimal))
        (assert.are.equal :high (shared.clamp-reasoning-effort "gpt-5.5" :high))))

    (it "clamps :xhigh to :high on gpt-5.1"
      (fn []
        (assert.are.equal :high (shared.clamp-reasoning-effort "gpt-5.1" :xhigh))
        (assert.are.equal :medium (shared.clamp-reasoning-effort "gpt-5.1" :medium))))

    (it "clamps gpt-5.1-codex-mini to :high or :medium"
      (fn []
        (assert.are.equal :high (shared.clamp-reasoning-effort "gpt-5.1-codex-mini" :high))
        (assert.are.equal :high (shared.clamp-reasoning-effort "gpt-5.1-codex-mini" :xhigh))
        (assert.are.equal :medium (shared.clamp-reasoning-effort "gpt-5.1-codex-mini" :low))))

    (it "passes through for unknown models"
      (fn []
        (assert.are.equal :high (shared.clamp-reasoning-effort "gpt-4o" :high))
        (assert.are.equal :minimal (shared.clamp-reasoning-effort "gpt-4o" :minimal))))))

(describe "providers.openai_responses build-url"
  (fn []
    (it "appends /responses to a v1-root base URL"
      (fn []
        (assert.are.equal "https://api.openai.com/v1/responses"
                          (responses.build-url "https://api.openai.com/v1"))))

    (it "respects an already-fully-qualified responses URL"
      (fn []
        (assert.are.equal "https://api.openai.com/v1/responses"
                          (responses.build-url "https://api.openai.com/v1/responses"))))))

(describe "providers.openai_responses build-body"
  (fn []
    (it "puts the system prompt in `instructions`, not in `input`"
      (fn []
        (let [body (responses.build-body
                     "gpt-5.5"
                     {:system-prompt "be helpful"
                      :messages [(types.user-message "hi")]
                      :tools []}
                     16384 {})]
          (assert.are.equal "be helpful" body.instructions)
          (assert.are.equal :user (. body.input 1 :role))
          ;; Input has no `system` role — that's the Chat Completions shape.
          (assert.are.equal 1 (length body.input)))))

    (it "sets stream:true and store:false"
      (fn []
        (let [body (responses.build-body "m"
                     {:system-prompt nil :messages [] :tools []} 64 {})]
          (assert.is_true body.stream)
          (assert.is_false body.store))))

    (it "sets max_output_tokens (not max_completion_tokens)"
      (fn []
        (let [body (responses.build-body "m"
                     {:system-prompt nil :messages [] :tools []} 256 {})]
          (assert.are.equal 256 body.max_output_tokens)
          (assert.is_nil body.max_completion_tokens)
          (assert.is_nil body.max_tokens))))

    (it "adds tool_choice + parallel_tool_calls when tools are present"
      (fn []
        (let [body (responses.build-body "m"
                     {:system-prompt nil :messages []
                      :tools [{:name "ls" :description "" :parameters {:type :object}}]}
                     64 {})]
          (assert.are.equal 1 (length body.tools))
          (assert.are.equal :auto body.tool_choice)
          (assert.is_true body.parallel_tool_calls))))

    (it "carries reasoning effort with summary:auto when set, clamped per-model"
      (fn []
        (let [body (responses.build-body "gpt-5.5"
                     {:system-prompt nil :messages [] :tools []}
                     64 {:reasoning-effort :minimal})]
          ;; gpt-5.5 clamps :minimal → :low.
          (assert.are.equal :low (. body :reasoning :effort))
          (assert.are.equal :auto (. body :reasoning :summary)))))

    (it "carries text.verbosity, include[], service_tier, prompt_cache_key when set"
      (fn []
        (let [body (responses.build-body "m"
                     {:system-prompt nil :messages [] :tools []} 64
                     {:verbosity :low
                      :include ["reasoning.encrypted_content"]
                      :service-tier :priority
                      :prompt-cache-key "session-abc"})]
          (assert.are.equal :low (. body :text :verbosity))
          (assert.are.equal "reasoning.encrypted_content" (. body :include 1))
          (assert.are.equal :priority body.service_tier)
          (assert.are.equal "session-abc" body.prompt_cache_key))))))

(describe "providers.openai_responses_shared end-to-end SSE"
  (fn []
    (it "drives a real SSE fixture through the parser+reducer"
      (fn []
        (let [raw
              (.. "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}\n\n"
                  "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n"
                  "data: {\"type\":\"response.output_text.delta\",\"delta\":\", world\"}\n\n"
                  "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello, world\"}]}}\n\n"
                  "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8}}}\n\n"
                  "data: [DONE]\n\n")
              seen []
              asst (run-sse raw #(table.insert seen $1))]
          (assert.are.equal :stop asst.stop-reason)
          (assert.are.equal "Hello, world" (. asst.content 1 :text))
          (assert.are.equal 5 asst.usage.input)
          (assert.are.equal :done (. seen (length seen) :type)))))

    (it "tolerates 1-byte SSE chunk boundaries"
      (fn []
        (let [raw
              (.. "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}\n\n"
                  "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n"
                  "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}}\n\n"
                  "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}\n\n")
              state (shared.new-stream-state "m")
              parser (sse.new-parser
                       (fn [ev]
                         (when (and (not= ev.data nil)
                                    (not= ev.data "")
                                    (not= ev.data "[DONE]"))
                           (let [(ok? decoded) (pcall json.decode ev.data)]
                             (when ok?
                               (shared.process-event! state decoded nil))))))]
          (for [i 1 (length raw)]
            (parser.feed (string.sub raw i i)))
          (parser.finish)
          (let [asst (shared.finalize-stream-state state :openai-responses :openai nil)]
            (assert.are.equal :stop asst.stop-reason)
            (assert.are.equal "hi" (. asst.content 1 :text))))))))
