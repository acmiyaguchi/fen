;; Wire-conversion and streaming-reducer tests for the OpenAI Responses
;; provider. Fixture event sequences mirror the shapes produced by
;; api.openai.com/v1/responses; the same shapes (with a few aliases) feed
;; the Codex Responses provider added in phase 3.

(local shared (require :fen.extensions.provider_openai.openai_responses_shared))
(local responses (require :fen.extensions.provider_openai.openai_responses))
(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local sse (require :fen.util.sse))
(local diagnostics (require :fen.core.diagnostics))

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

(fn stub-parser []
  "A parser whose feed/finish are no-ops; finalize-stream only calls finish."
  {:feed (fn [_chunk] nil)
   :finish (fn [] nil)})

(fn capture-events []
  "Return (events emit) where emit records into the events array."
  (let [events []]
    (values events (fn [ev] (table.insert events ev)))))

(fn terminal-event [events]
  (var out nil)
  (each [_ ev (ipairs events)]
    (when (or (= ev.type :done) (= ev.type :error))
      (set out ev)))
  out)

(fn cleanup-diagnostic! [asst]
  "finalize-stream writes a real failure diagnostic and appends its path to the
   error message. Remove exactly that file so error-path tests don't litter the
   state dir; the path has no spaces (safe-name + timestamp + random)."
  (when (and asst asst.error-message)
    (let [path (string.match asst.error-message "Diagnostic: (%S+)")]
      (when path (os.remove path)))))

;; finalize-stream is the resp-aware wrapper (transport/HTTP/parser/incomplete
;; branches) that turns the streamed state into a final AssistantMessage. It is
;; distinct from finalize-stream-state (the pure reducer-finalizer exercised
;; above) and was previously untested.
(describe "providers.openai_responses_shared.finalize-stream"
  (fn []
    (it "maps a transport error to an error assistant message"
      (fn []
        (let [state (shared.new-stream-state "gpt-5.5")
              (events emit) (capture-events)
              resp {:error "Couldn't connect to server" :curl-code 7}
              asst (shared.finalize-stream
                     state (stub-parser) {:message nil}
                     :openai-responses :openai "gpt-5.5" resp emit nil)]
          (assert.are.equal :error asst.stop-reason)
          (assert.is_not_nil
            (string.find asst.error-message "Couldn't connect" 1 true))
          (assert.are.equal :error (. (terminal-event events) :type))
          (cleanup-diagnostic! asst))))

    (it "maps a non-2xx HTTP status to an error assistant message"
      (fn []
        (let [state (shared.new-stream-state "gpt-5.5")
              (events emit) (capture-events)
              resp {:status 500 :body "upstream boom" :headers {}}
              asst (shared.finalize-stream
                     state (stub-parser) {:message nil}
                     :openai-responses :openai "gpt-5.5" resp emit nil)]
          (assert.are.equal :error asst.stop-reason)
          (assert.is_not_nil (string.find asst.error-message "HTTP 500" 1 true))
          (assert.is_not_nil (string.find asst.error-message "upstream boom" 1 true))
          (assert.are.equal :error (. (terminal-event events) :type))
          (cleanup-diagnostic! asst))))

    (it "maps a mid-stream JSON parse error to an error assistant message"
      (fn []
        (let [state (shared.new-stream-state "gpt-5.5")
              (events emit) (capture-events)
              resp {:status 200 :body "data: {bad" :headers {}}
              asst (shared.finalize-stream
                     state (stub-parser) {:message "parse failed near {bad"}
                     :openai-responses :openai "gpt-5.5" resp emit nil)]
          (assert.are.equal :error asst.stop-reason)
          (assert.is_not_nil (string.find asst.error-message "parse failed" 1 true))
          (assert.are.equal :error (. (terminal-event events) :type))
          (cleanup-diagnostic! asst))))

    (it "treats a 200 stream with no terminal event as an incomplete error"
      (fn []
        ;; Real-world stall: a text delta arrived but the connection closed
        ;; before response.completed. Previously this finalized as an empty
        ;; :stop success the agent loop swallowed silently.
        (let [state (shared.new-stream-state "gpt-5.5")
              (events emit) (capture-events)]
          (shared.process-event! state
            {:type :response.output_item.added
             :item {:type :message :id "msg_1"}} nil)
          (shared.process-event! state
            {:type :response.output_text.delta :delta "partial"} nil)
          (assert.is_false state.saw-terminal?)
          (let [resp {:status 200 :body "partial" :headers {}}
                asst (shared.finalize-stream
                       state (stub-parser) {:message nil}
                       :openai-responses :openai "gpt-5.5" resp emit nil)]
            (assert.are.equal :error asst.stop-reason)
            (assert.is_not_nil
              (string.find asst.error-message "without a completion event" 1 true))
            (assert.are.equal :error (. (terminal-event events) :type))
            (cleanup-diagnostic! asst)))))

    (it "treats a 200 empty body as an incomplete error"
      (fn []
        (let [state (shared.new-stream-state "gpt-5.5")
              (events emit) (capture-events)
              resp {:status 200 :body "" :headers {}}
              asst (shared.finalize-stream
                     state (stub-parser) {:message nil}
                     :openai-responses :openai "gpt-5.5" resp emit nil)]
          (assert.are.equal :error asst.stop-reason)
          (assert.is_not_nil
            (string.find asst.error-message "without a completion event" 1 true))
          (cleanup-diagnostic! asst))))

    (it "finalizes a normal completed stream as a success"
      (fn []
        (let [state (shared.new-stream-state "gpt-5.5")
              (events emit) (capture-events)]
          (shared.process-event! state
            {:type :response.output_item.added
             :item {:type :message :id "msg_1"}} nil)
          (shared.process-event! state
            {:type :response.output_text.delta :delta "hi"} nil)
          (shared.process-event! state
            {:type :response.completed
             :response {:id "resp_1" :status :completed}} nil)
          (assert.is_true state.saw-terminal?)
          (let [resp {:status 200 :body "ok" :headers {}}
                asst (shared.finalize-stream
                       state (stub-parser) {:message nil}
                       :openai-responses :openai "gpt-5.5" resp emit nil)]
            (assert.are.equal :stop asst.stop-reason)
            (assert.are.equal :done (. (terminal-event events) :type))))))

    (it "treats response.incomplete as a terminal :length stop"
      (fn []
        (let [state (shared.new-stream-state "gpt-5.5")
              (events emit) (capture-events)]
          (shared.process-event! state
            {:type :response.output_item.added
             :item {:type :message :id "msg_1"}} nil)
          (shared.process-event! state
            {:type :response.output_text.delta :delta "hi"} nil)
          (shared.process-event! state
            {:type :response.incomplete
             :response {:id "resp_1" :status :incomplete}} nil)
          (assert.is_true state.saw-terminal?)
          (assert.are.equal :length state.stop-reason)
          (let [resp {:status 200 :body "ok" :headers {}}
                asst (shared.finalize-stream
                       state (stub-parser) {:message nil}
                       :openai-responses :openai "gpt-5.5" resp emit nil)]
            (assert.are.equal :length asst.stop-reason)
            (assert.are.equal :done (. (terminal-event events) :type))))))))

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

    (it "JSON-encodes annotations as an array, not an object"
      ;; Regression: cjson encodes empty Lua tables as `{}`. The Responses
      ;; API rejects `annotations: {}` with `expected an array of objects`.
      ;; Must use cjson's empty-array sentinel so the wire stays `[]`.
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.text-block "answer")]
                      :stop-reason :stop})
              out (shared.convert-messages [asst])
              encoded (json.encode out)]
          (assert.is_truthy
            (string.find encoded "\"annotations\":%[%]"))
          (assert.is_nil
            (string.find encoded "\"annotations\":%{%}")))))

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

    (it "converts a tool-result paired with its call to {type:function_call_output}"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.tool-call-block
                                  "call_abc|fc_xyz" "bash" {:cmd "ls"})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_abc|fc_xyz" :tool-name "bash"
                    :content [(types.text-block "stdout!")]})
              out (shared.convert-messages [asst tr])]
          (assert.are.equal 2 (length out))
          (assert.are.equal :function_call (. out 1 :type))
          (assert.are.equal :function_call_output (. out 2 :type))
          (assert.are.equal "call_abc" (. out 2 :call_id))
          (assert.are.equal "stdout!" (. out 2 :output)))))

    (it "repairs unsafe legacy tool-result output before Responses replay (#130)"
      (fn []
        (let [unsafe (.. "a" (string.char 0) "b" (string.char 5) "\n")
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.tool-call-block
                                  "call_bad|fc_bad" "bash" {:cmd "cat /dev/pps"})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_bad|fc_bad" :tool-name "bash"
                    :content [(types.text-block unsafe)]})
              out (shared.convert-messages [asst tr])
              output (. out 2 :output)]
          (assert.are.equal :function_call_output (. out 2 :type))
          (assert.are.equal "call_bad" (. out 2 :call_id))
          (assert.is_nil (string.find output (string.char 0) 1 true))
          (assert.is_nil (string.find output (string.char 5) 1 true))
          (assert.is_truthy (string.find output "\\x00" 1 true))
          (assert.is_truthy (string.find output "\\x05" 1 true))
          (assert.is_truthy (string.find output "tool output sanitized" 1 true)))))

    (it "caps oversized legacy tool-result output before Responses replay (#130)"
      (fn []
        (let [big (string.rep "x" 70000)
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.tool-call-block
                                  "call_big|fc_big" "bash" {:cmd "cat huge.log"})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_big|fc_big" :tool-name "bash"
                    :content [(types.text-block big)]})
              out (shared.convert-messages [asst tr])
              output (. out 2 :output)]
          (assert.are.equal :function_call_output (. out 2 :type))
          (assert.are.equal "call_big" (. out 2 :call_id))
          (assert.is_true (< (length output) (length big)))
          (assert.is_truthy (string.find output "tool output truncated" 1 true)))))

    (it "drops an orphaned function_call_output with no matching emitted call (#3)"
      ;; A lone tool-result (model switch / partial projection / hand-edited
      ;; session) would 400 with "No tool call found for function call
      ;; output with call_id ..." and wedge every future turn.
      (fn []
        (let [tr (types.tool-result-message
                   {:tool-call-id "call_nope|fc_z" :tool-name "bash"
                    :content [(types.text-block "out")]})
              out (shared.convert-messages [tr (types.user-message "next")])]
          (assert.are.equal 1 (length out))
          (assert.are.equal :user (. out 1 :role))
          ;; No synthetic placeholder either — pending tracks missing
          ;; outputs, not missing calls.
          (assert.is_nil (. out 2)))))

    (it "synthesizes missing outputs for orphaned tool calls in replayed history"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.tool-call-block
                                  "call_orphan|fc_1" "agent_state" {})]
                      :stop-reason :tool-use})
              out (shared.convert-messages [asst (types.user-message "continue")])]
          (assert.are.equal 3 (length out))
          (assert.are.equal :function_call (. out 1 :type))
          (assert.are.equal :function_call_output (. out 2 :type))
          (assert.are.equal "call_orphan" (. out 2 :call_id))
          (assert.is_truthy (string.find (. out 2 :output) "missing tool output" 1 true))
          (assert.are.equal :user (. out 3 :role)))))

    (it "strips the fc_ item id and drops reasoning for a cross-model turn (#1)"
      ;; Resuming / switching models replays another model's fc_/rs_ ids;
      ;; OpenAI pairing validation 400s and store:false makes it permanent.
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_old"
                              :summary [{:type :summary_text :text "old"}]}
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "old-model"
                      :content [(types.thinking-block
                                  {:thinking "old"
                                   :thinking-signature (json.encode reasoning-item)})
                                (types.tool-call-block "call_x|fc_y" "bash" {:cmd "ls"})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_x|fc_y" :tool-name "bash"
                    :content [(types.text-block "ok")]})
              out (shared.convert-messages [asst tr] {:model "new-model"})]
          (assert.are.equal 2 (length out))
          (assert.are.equal :function_call (. out 1 :type))
          (assert.are.equal "call_x" (. out 1 :call_id))
          (assert.is_nil (. out 1 :id))
          (assert.are.equal "bash" (. out 1 :name))
          (assert.are.equal :function_call_output (. out 2 :type)))))

    (it "keeps the fc_ id and reasoning when the assistant model matches (#1)"
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_1"
                              :summary [{:type :summary_text :text "thoughts"}]}
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.thinking-block
                                  {:thinking "thoughts"
                                   :thinking-signature (json.encode reasoning-item)})
                                (types.tool-call-block "call_x|fc_y" "bash" {})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_x|fc_y" :tool-name "bash"
                    :content [(types.text-block "ok")]})
              out (shared.convert-messages [asst tr] {:model "m"})]
          (assert.are.equal 3 (length out))
          (assert.are.equal :reasoning (. out 1 :type))
          (assert.are.equal :function_call (. out 2 :type))
          (assert.are.equal "fc_y" (. out 2 :id))
          (assert.are.equal :function_call_output (. out 3 :type)))))

    (it "does not strip cross-model shapes when called with one arg (#1 back-compat)"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "old-model"
                      :content [(types.tool-call-block "call_x|fc_y" "bash" {})]
                      :stop-reason :tool-use})
              out (shared.convert-messages [asst])]
          (assert.are.equal :function_call (. out 1 :type))
          (assert.are.equal "fc_y" (. out 1 :id)))))

    (it "drops a reasoning-only assistant turn with no following output (#2)"
      ;; stop-reason :length/:incomplete after reasoning-only: a lone
      ;; reasoning item 400s ("provided without its required following item").
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_1"
                              :summary [{:type :summary_text :text "thoughts"}]}
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.thinking-block
                                  {:thinking "thoughts"
                                   :thinking-signature (json.encode reasoning-item)})]
                      :stop-reason :length})
              out (shared.convert-messages [asst (types.user-message "go on")])]
          (assert.are.equal 1 (length out))
          (assert.are.equal :user (. out 1 :role)))))

    (it "keeps reasoning when the same turn also has a tool-call (#2)"
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_1"
                              :summary [{:type :summary_text :text "thoughts"}]}
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.thinking-block
                                  {:thinking "thoughts"
                                   :thinking-signature (json.encode reasoning-item)})
                                (types.tool-call-block "call_a|fc_b" "bash" {})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_a|fc_b" :tool-name "bash"
                    :content [(types.text-block "ok")]})
              out (shared.convert-messages [asst tr])]
          (assert.are.equal 3 (length out))
          (assert.are.equal :reasoning (. out 1 :type))
          (assert.are.equal :function_call (. out 2 :type))
          (assert.are.equal :function_call_output (. out 3 :type)))))

    (it "still pairs a cross-model tool-call with its result by call_id (#1/#3)"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "old-model"
                      :content [(types.tool-call-block "call_p|fc_q" "bash" {})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_p|fc_q" :tool-name "bash"
                    :content [(types.text-block "done")]})
              out (shared.convert-messages [asst tr] {:model "new-model"})]
          (assert.are.equal 2 (length out))
          (assert.are.equal :function_call (. out 1 :type))
          (assert.is_nil (. out 1 :id))
          (assert.are.equal "call_p" (. out 1 :call_id))
          (assert.are.equal :function_call_output (. out 2 :type))
          (assert.are.equal "call_p" (. out 2 :call_id))
          (assert.are.equal "done" (. out 2 :output)))))

    (it "drops a trailing reasoning item with no following output (#2)"
      ;; Reasoning after the message/tool-call (interleaved or incomplete
      ;; turn) also 400s with store:false, not just reasoning-only turns.
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_t"
                              :summary [{:type :summary_text :text "after"}]}
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.text-block "answer")
                                (types.thinking-block
                                  {:thinking "after"
                                   :thinking-signature (json.encode reasoning-item)})]
                      :stop-reason :stop})
              out (shared.convert-messages [asst])]
          (assert.are.equal 1 (length out))
          (assert.are.equal :message (. out 1 :type)))))

    (it "keeps interleaved reasoning items, each followed by a tool-call (#2)"
      (fn []
        (let [r1 {:type :reasoning :id "rs_1"
                  :summary [{:type :summary_text :text "one"}]}
              r2 {:type :reasoning :id "rs_2"
                  :summary [{:type :summary_text :text "two"}]}
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.thinking-block
                                  {:thinking "one"
                                   :thinking-signature (json.encode r1)})
                                (types.tool-call-block "call_1|fc_1" "bash" {})
                                (types.thinking-block
                                  {:thinking "two"
                                   :thinking-signature (json.encode r2)})
                                (types.tool-call-block "call_2|fc_2" "bash" {})]
                      :stop-reason :tool-use})
              tr1 (types.tool-result-message
                    {:tool-call-id "call_1|fc_1" :tool-name "bash"
                     :content [(types.text-block "a")]})
              tr2 (types.tool-result-message
                    {:tool-call-id "call_2|fc_2" :tool-name "bash"
                     :content [(types.text-block "b")]})
              out (shared.convert-messages [asst tr1 tr2])]
          (assert.are.equal 6 (length out))
          (assert.are.equal :reasoning (. out 1 :type))
          (assert.are.equal :function_call (. out 2 :type))
          (assert.are.equal :reasoning (. out 3 :type))
          (assert.are.equal :function_call (. out 4 :type))
          (assert.are.equal :function_call_output (. out 5 :type))
          (assert.are.equal :function_call_output (. out 6 :type)))))

    (it "drops a duplicate function_call_output for an already-paired call (#3)"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.tool-call-block "call_a|fc_a" "bash" {})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_a|fc_a" :tool-name "bash"
                    :content [(types.text-block "out")]})
              out (shared.convert-messages [asst tr tr])]
          (assert.are.equal 2 (length out))
          (assert.are.equal :function_call (. out 1 :type))
          (assert.are.equal :function_call_output (. out 2 :type)))))

    (it "does not double-emit when a real result arrives after a synthesized one (#3)"
      (fn []
        (let [asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.tool-call-block "call_a|fc_a" "bash" {})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_a|fc_a" :tool-name "bash"
                    :content [(types.text-block "late")]})
              out (shared.convert-messages
                    [asst (types.user-message "hi") tr])]
          (assert.are.equal 3 (length out))
          (assert.are.equal :function_call (. out 1 :type))
          (assert.are.equal :function_call_output (. out 2 :type))
          (assert.is_truthy
            (string.find (. out 2 :output) "missing tool output" 1 true))
          (assert.are.equal :user (. out 3 :role))
          (var n 0)
          (each [_ it (ipairs out)]
            (when (= it.type :function_call_output) (set n (+ n 1))))
          (assert.are.equal 1 n))))

    (it "treats same model-id from a different backend as foreign (#1 cross-backend)"
      ;; Codex (chatgpt.com) ↔ vanilla (api.openai.com) can share a model id;
      ;; the rs_/fc_ ids are still backend-scoped and 400 if replayed.
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_cdx"
                              :summary [{:type :summary_text :text "cdx"}]}
              asst (types.assistant-message
                     {:api :openai-codex-responses :provider :openai-codex
                      :model "gpt-5.2"
                      :content [(types.thinking-block
                                  {:thinking "cdx"
                                   :thinking-signature (json.encode reasoning-item)})
                                (types.tool-call-block "call_c|fc_c" "bash" {})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_c|fc_c" :tool-name "bash"
                    :content [(types.text-block "ok")]})
              out (shared.convert-messages
                    [asst tr]
                    {:model "gpt-5.2" :api :openai-responses :provider :openai})]
          ;; reasoning dropped, fc_ id stripped, output still paired.
          (assert.are.equal 2 (length out))
          (assert.are.equal :function_call (. out 1 :type))
          (assert.is_nil (. out 1 :id))
          (assert.are.equal "call_c" (. out 1 :call_id))
          (assert.are.equal :function_call_output (. out 2 :type)))))

    (it "keeps reasoning/fc_ when model, api and provider all match (#1)"
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_s"
                              :summary [{:type :summary_text :text "s"}]}
              asst (types.assistant-message
                     {:api :openai-responses :provider :openai :model "m"
                      :content [(types.thinking-block
                                  {:thinking "s"
                                   :thinking-signature (json.encode reasoning-item)})
                                (types.tool-call-block "call_s|fc_s" "bash" {})]
                      :stop-reason :tool-use})
              tr (types.tool-result-message
                   {:tool-call-id "call_s|fc_s" :tool-name "bash"
                    :content [(types.text-block "ok")]})
              out (shared.convert-messages
                    [asst tr]
                    {:model "m" :api :openai-responses :provider :openai})]
          (assert.are.equal 3 (length out))
          (assert.are.equal :reasoning (. out 1 :type))
          (assert.are.equal :function_call (. out 2 :type))
          (assert.are.equal "fc_s" (. out 2 :id))
          (assert.are.equal :function_call_output (. out 3 :type)))))

    (it "does not over-strip when only ?model is supplied (#1 partial identity)"
      ;; api differs but the request side passes no api ⇒ that dimension is
      ;; unknown and must not trigger the repair (back-compat for callers
      ;; that only thread the model string).
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_p"
                              :summary [{:type :summary_text :text "p"}]}
              asst (types.assistant-message
                     {:api :openai-codex-responses :provider :openai-codex
                      :model "m"
                      :content [(types.thinking-block
                                  {:thinking "p"
                                   :thinking-signature (json.encode reasoning-item)})
                                (types.text-block "answer")]
                      :stop-reason :stop})
              out (shared.convert-messages [asst] {:model "m"})]
          (assert.are.equal 2 (length out))
          (assert.are.equal :reasoning (. out 1 :type))
          (assert.are.equal :message (. out 2 :type)))))))

(describe "providers.openai_responses_shared failure diagnostics"
  (fn []
    (it "redacts sensitive headers"
      (fn []
        (let [headers (shared.redact-headers
                        {:authorization "Bearer secret"
                         :chatgpt-account-id "acct"
                         :accept "text/event-stream"})]
          (assert.are.equal "[redacted]" headers.authorization)
          (assert.are.equal "[redacted]" headers.chatgpt-account-id)
          (assert.are.equal "text/event-stream" headers.accept))))

    (it "includes runtime metadata in provider failure diagnostics"
      (fn []
        (diagnostics.set-runtime-info! {:version "test-version" :source "test"})
        (let [doc (shared.failure-diagnostic
                    :openai-codex-responses :openai-codex "gpt-5.5"
                    {:error "Transferred a partial file" :curl-code 18}
                    {:method :POST :url "https://example.invalid"}
                    :transport)]
          (assert.are.equal 18 doc.http.curl-code)
          (assert.is_table doc.runtime)
          (assert.are.equal "test-version" doc.runtime.version)
          (assert.are.equal "test" doc.runtime.source))))

    (it "summarizes request bodies without prompt or tool output text"
      (fn []
        (let [body {:model "gpt-5.5"
                    :stream true
                    :store false
                    :instructions "secret system prompt"
                    :input [{:role :user
                             :content [{:type :input_text :text "secret user text"}]}
                            {:type :function_call
                             :call_id "call_1"
                             :id "fc_1"
                             :name "bash"
                             :arguments "{\"cmd\":\"secret command\"}"}
                            {:type :function_call_output
                             :call_id "call_1"
                             :output "secret stdout"}]
                    :tools [{:type :function :name "bash" :parameters {:type :object}}]}
              summary (shared.summarize-body body)
              encoded (json.encode summary)]
          (assert.are.equal "gpt-5.5" summary.model)
          (assert.are.equal 3 summary.input-count)
          (assert.are.equal 1 summary.tools-count)
          (assert.are.equal (length "secret system prompt") summary.instructions-length)
          (assert.are.equal (length "secret user text") (. summary :input 1 :content 1 :text-length))
          (assert.are.equal (length "{\"cmd\":\"secret command\"}") (. summary :input 2 :arguments-length))
          (assert.are.equal (length "secret stdout") (. summary :input 3 :output-length))
          (assert.are.equal 1 (. summary :function-call-outputs :count))
          (assert.are.equal (length "secret stdout")
                            (. summary :function-call-outputs :max-output-length))
          (assert.are.equal (length "secret stdout")
                            (. summary :function-call-outputs :cumulative-output-length))
          (assert.are.equal 0 (. summary :function-call-outputs :sanitized-count))
          (assert.are.equal 0 (. summary :function-call-outputs :truncated-count))
          (assert.is_nil (string.find encoded "secret user text" 1 true))
          (assert.is_nil (string.find encoded "secret command" 1 true))
          (assert.is_nil (string.find encoded "secret stdout" 1 true)))))

    (it "flags repaired function outputs in redacted diagnostics (#130)"
      (fn []
        (let [body {:input [{:type :function_call_output
                             :call_id "call_s"
                             :output "ok\n\n[fen: tool output sanitized: 1 unsafe bytes escaped]"}
                            {:type :function_call_output
                             :call_id "call_t"
                             :output "xx\n\n[fen: tool output truncated: kept 2 of 10 sanitized bytes]"}]}
              summary (shared.summarize-body body)
              stats summary.function-call-outputs]
          (assert.are.equal 2 stats.count)
          (assert.are.equal 1 stats.sanitized-count)
          (assert.are.equal 1 stats.truncated-count)
          (assert.are.equal 2 (length stats.affected))
          (assert.are.equal "call_s" (. stats :affected 1 :call-id))
          (assert.is_true (. stats :affected 1 :sanitized?))
          (assert.are.equal "call_t" (. stats :affected 2 :call-id))
          (assert.is_true (. stats :affected 2 :truncated?)))))))

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

    (it "captures reasoning_text deltas as canonical thinking"
      (fn []
        (let [reasoning-item {:type :reasoning :id "rs_2"
                              :content [{:type :reasoning_text :text "raw thought"}]}
              events
              [{:type :response.output_item.added
                :item {:type :reasoning :id "rs_2"}}
               {:type :response.reasoning_text.delta :delta "raw "}
               {:type :response.reasoning_text.delta :delta "thought"}
               {:type :response.output_item.done :item reasoning-item}
               {:type :response.completed
                :response {:status :completed
                           :usage {:input_tokens 0 :output_tokens 0 :total_tokens 0}}}]
              seen []
              asst (run-events events #(table.insert seen $1))
              thinking (. asst.content 1)]
          (assert.are.equal :thinking thinking.type)
          (assert.are.equal "raw thought" thinking.thinking)
          (assert.are.equal :thinking-start (. seen 1 :type))
          (assert.are.equal :thinking-delta (. seen 2 :type))
          (assert.are.equal "raw " (. seen 2 :delta))
          (assert.are.equal :thinking-delta (. seen 3 :type))
          (assert.are.equal :thinking-end (. seen 4 :type)))))

    (it "opens a thinking block for reasoning deltas without output_item.added"
      (fn []
        (let [events
              [{:type :response.reasoning_text.delta :delta "raw "}
               {:type :response.reasoning_text.delta :delta "thought"}
               {:type :response.completed
                :response {:status :completed
                           :usage {:input_tokens 0 :output_tokens 0 :total_tokens 0}}}]
              seen []
              asst (run-events events #(table.insert seen $1))
              thinking (. asst.content 1)]
          (assert.are.equal :thinking thinking.type)
          (assert.are.equal "raw thought" thinking.thinking)
          (assert.are.equal :thinking-start (. seen 1 :type))
          (assert.are.equal :thinking-delta (. seen 2 :type))
          (assert.are.equal :thinking-delta (. seen 3 :type))
          (assert.are.equal :thinking-end (. seen 4 :type)))))

    (it "finalizes a reasoning block from output_item.done without output_item.added"
      (fn []
        (let [events
              [{:type :response.output_item.done
                :item {:type :reasoning :id "rs_3"
                       :summary [{:type :summary_text :text "final thought"}]}}
               {:type :response.completed
                :response {:status :completed
                           :usage {:input_tokens 0 :output_tokens 0 :total_tokens 0}}}]
              seen []
              asst (run-events events #(table.insert seen $1))
              thinking (. asst.content 1)]
          (assert.are.equal :thinking thinking.type)
          (assert.are.equal "final thought" thinking.thinking)
          (assert.are.equal :thinking-start (. seen 1 :type))
          (assert.are.equal :thinking-end (. seen 2 :type)))))

    (it "uses reasoning_summary_text.done as a final snapshot"
      (fn []
        (let [events
              [{:type :response.output_item.added
                :item {:type :reasoning :id "rs_4"}}
               {:type :response.reasoning_summary_text.delta :delta "partial"}
               {:type :response.reasoning_summary_text.done :text "final thought"}
               {:type :response.output_item.done
                :item {:type :reasoning :id "rs_4"
                       :summary [{:type :summary_text :text "final thought"}]}}
               {:type :response.completed
                :response {:status :completed
                           :usage {:input_tokens 0 :output_tokens 0 :total_tokens 0}}}]
              asst (run-events events nil)
              thinking (. asst.content 1)]
          (assert.are.equal :thinking thinking.type)
          (assert.are.equal "final thought" thinking.thinking))))

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
          (assert.is_truthy (string.find asst.error-message "server_error" 1 true)))))

    (it "ignores non-table stream events and fields without callback errors"
      (fn []
        (let [state (shared.new-stream-state "gpt-5.5")
              userdata (io.tmpfile)
              events [userdata
                      {:type :response.created :response userdata}
                      {:type :response.output_item.added :item userdata}
                      {:type :response.function_call_arguments.delta :delta userdata}
                      {:type :response.function_call_arguments.done :arguments userdata}
                      {:type :response.output_item.done :item userdata}
                      {:type :response.completed :response userdata}
                      {:type :response.failed :response userdata}
                      {:type :error :code userdata :message userdata}]
              (ok? err) (pcall
                          (fn []
                            (each [_ ev (ipairs events)]
                              (shared.process-event! state ev nil))))]
          (when userdata (userdata:close))
          (assert.is_true ok?)
          (assert.is_nil err)
          (assert.are.equal :error state.stop-reason)
          (assert.is_string state.error-message))))))

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
          (assert.are.equal "session-abc" body.prompt_cache_key))))

    ;; store:false + reasoning round-trips only if the encrypted payload is
    ;; requested; otherwise replaying a bare rs_ id 404s on a tool turn (#132).
    (it "requests reasoning.encrypted_content whenever reasoning is enabled"
      (fn []
        (let [body (responses.build-body "gpt-5.5"
                     {:system-prompt nil :messages [] :tools []}
                     64 {:reasoning-effort :high})]
          (assert.are.equal "reasoning.encrypted_content" (. body :include 1)))))

    (it "omits include when reasoning is not enabled"
      (fn []
        (let [body (responses.build-body "m"
                     {:system-prompt nil :messages [] :tools []} 64 {})]
          (assert.is_nil body.include))))

    (it "does not duplicate reasoning.encrypted_content already supplied"
      (fn []
        (let [body (responses.build-body "gpt-5.5"
                     {:system-prompt nil :messages [] :tools []}
                     64 {:reasoning-effort :high
                         :include ["reasoning.encrypted_content"]})]
          (assert.are.equal 1 (length body.include))
          (assert.are.equal "reasoning.encrypted_content" (. body :include 1)))))))

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

;; Codex store:false reasoning poison-pill (#132): a turn with function_call
;; items but no rs_ reasoning 400s forever. Fix A recovers a dropped
;; reasoning item from the terminal response.completed.output; Fix B strips
;; the fc_ item id from any same-backend turn that ends up reasoning-less.
(describe "providers.openai_responses_shared #132 reasoning poison"
  (fn []
    (let [id {:model "gpt-5.5"
              :api :openai-codex-responses
              :provider :openai-codex}
          fc-events
          [{:type :response.output_item.added
            :item {:type :function_call :call_id "call_1" :id "fc_1"
                   :name "bash" :arguments "{\"cmd\":\"ls\"}"}}
           {:type :response.output_item.done
            :item {:type :function_call :call_id "call_1" :id "fc_1"
                   :name "bash" :arguments "{\"cmd\":\"ls\"}"}}
           {:type :response.output_item.added
            :item {:type :function_call :call_id "call_2" :id "fc_2"
                   :name "bash" :arguments "{\"cmd\":\"pwd\"}"}}
           {:type :response.output_item.done
            :item {:type :function_call :call_id "call_2" :id "fc_2"
                   :name "bash" :arguments "{\"cmd\":\"pwd\"}"}}]
          completed-with-reasoning
          {:type :response.completed
           :response {:id "resp_1" :status :completed
                      :usage {:input_tokens 5 :output_tokens 2
                              :total_tokens 7}
                      :output [{:type :reasoning :id "rs_1"
                                :encrypted_content "ENC"}
                               {:type :function_call :call_id "call_1"
                                :id "fc_1" :name "bash"
                                :arguments "{\"cmd\":\"ls\"}"}
                               {:type :function_call :call_id "call_2"
                                :id "fc_2" :name "bash"
                                :arguments "{\"cmd\":\"pwd\"}"}]}}]

      ;; ---- Fix B: convert-messages strips fc_ on reasoning-less turns ----

      (it "strips fc_ on a same-backend turn with tool-calls but no reasoning"
        (fn []
          (let [asst (types.assistant-message
                       {:api :openai-codex-responses :provider :openai-codex
                        :model "gpt-5.5"
                        :content [(types.tool-call-block
                                    "call_a|fc_a" "bash" {:cmd "ls"})]
                        :stop-reason :tool-use})
                tr (types.tool-result-message
                     {:tool-call-id "call_a|fc_a" :tool-name "bash"
                      :content [(types.text-block "ok")]})
                out (shared.convert-messages [asst tr] id)]
            (assert.are.equal 2 (length out))
            (assert.are.equal :function_call (. out 1 :type))
            (assert.are.equal "call_a" (. out 1 :call_id))
            ;; fc_ stripped — backend can't pair it with a missing rs_.
            (assert.is_nil (. out 1 :id))
            (assert.are.equal :function_call_output (. out 2 :type))
            (assert.are.equal "call_a" (. out 2 :call_id)))))

      (it "keeps fc_ when the turn has a surviving reasoning item"
        (fn []
          (let [sig (json.encode {:type :reasoning :id "rs_keep"
                                  :encrypted_content "E"})
                asst (types.assistant-message
                       {:api :openai-codex-responses :provider :openai-codex
                        :model "gpt-5.5"
                        :content [(types.thinking-block
                                    {:thinking "" :thinking-signature sig})
                                  (types.tool-call-block
                                    "call_b|fc_b" "bash" {})]
                        :stop-reason :tool-use})
                out (shared.convert-messages [asst] id)]
            (assert.are.equal :reasoning (. out 1 :type))
            (assert.are.equal :function_call (. out 2 :type))
            (assert.are.equal "fc_b" (. out 2 :id)))))

      (it "strips fc_ when the only reasoning is trailing (dropped by #2)"
        (fn []
          (let [sig (json.encode {:type :reasoning :id "rs_t"})
                asst (types.assistant-message
                       {:api :openai-codex-responses :provider :openai-codex
                        :model "gpt-5.5"
                        :content [(types.tool-call-block
                                    "call_c|fc_c" "bash" {})
                                  (types.thinking-block
                                    {:thinking "" :thinking-signature sig})]
                        :stop-reason :tool-use})
                out (shared.convert-messages [asst] id)]
            (assert.are.equal :function_call (. out 1 :type))
            (assert.is_nil (. out 1 :id)))))

      ;; ---- Fix A: reducer recovers reasoning from response.completed ----

      (it "recovers a reasoning item the stream dropped, before its calls"
        (fn []
          (let [events []]
            (each [_ e (ipairs fc-events)] (table.insert events e))
            (table.insert events completed-with-reasoning)
            (let [asst (run-events events nil)]
              (assert.are.equal 3 (length asst.content))
              (assert.are.equal :thinking (. asst.content 1 :type))
              (assert.is_string (. asst.content 1 :thinking-signature))
              (let [dec (json.decode (. asst.content 1 :thinking-signature))]
                (assert.are.equal "rs_1" (. dec :id))
                (assert.are.equal "ENC" (. dec :encrypted_content)))
              (assert.are.equal :tool-call (. asst.content 2 :type))
              (assert.are.equal :tool-call (. asst.content 3 :type))
              (assert.are.equal :tool-use asst.stop-reason)))))

      (it "does not duplicate reasoning streamed normally (no-op guard)"
        (fn []
          (let [asst (run-events
                       [{:type :response.output_item.added
                         :item {:type :reasoning :id "rs_1"
                                :encrypted_content "ENC"}}
                        {:type :response.output_item.done
                         :item {:type :reasoning :id "rs_1"
                                :encrypted_content "ENC"}}
                        {:type :response.output_item.added
                         :item {:type :function_call :call_id "call_1"
                                :id "fc_1" :name "bash" :arguments "{}"}}
                        {:type :response.output_item.done
                         :item {:type :function_call :call_id "call_1"
                                :id "fc_1" :name "bash" :arguments "{}"}}
                        {:type :response.completed
                         :response {:id "r" :status :completed
                                    :usage {:input_tokens 1 :output_tokens 1
                                            :total_tokens 2}
                                    :output [{:type :reasoning :id "rs_1"
                                              :encrypted_content "ENC"}
                                             {:type :function_call
                                              :call_id "call_1" :id "fc_1"
                                              :name "bash" :arguments "{}"}]}}]
                       nil)]
            (assert.are.equal 2 (length asst.content))
            (assert.are.equal :thinking (. asst.content 1 :type))
            (assert.are.equal :tool-call (. asst.content 2 :type)))))

      (it "recovers dropped reasoning through the Codex response.done alias"
        (fn []
          (let [codex (require
                        :fen.extensions.provider_openai.openai_codex_responses)
                done-event {}
                events []]
            (each [k v (pairs completed-with-reasoning)]
              (tset done-event k v))
            (tset done-event :type :response.done)
            (each [_ e (ipairs fc-events)]
              (table.insert events (codex.map-codex-event e)))
            (table.insert events (codex.map-codex-event done-event))
            (let [asst (run-events events nil)]
              (assert.are.equal 3 (length asst.content))
              (assert.are.equal :thinking (. asst.content 1 :type))
              (let [dec (json.decode (. asst.content 1 :thinking-signature))]
                (assert.are.equal "rs_1" (. dec :id))))))))))
