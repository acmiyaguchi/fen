;; Shared OpenAI Responses-API stream reducer and message/tool conversions.
;;
;; Both the vanilla `openai-responses` provider (api.openai.com/v1/responses
;; with OPENAI_API_KEY) and the Codex subscription provider use this reducer.
;; Codex normalizes a few event aliases (`response.done`,
;; `response.incomplete`) before feeding events here.
;;
;; Mirrors pi-mono's `packages/ai/src/providers/openai-responses-shared.ts`,
;; simplified for fen's canonical types: no images, no
;; cost calculation, no service-tier pricing, no cross-provider id rewriting.

(local types (require :fen.core.types))
(local json (require :fen.util.json))

;; ----------------------------------------------------------------
;; Outbound: canonical → Responses input
;; ----------------------------------------------------------------

(fn text-of-content [content]
  (if (= (type content) :string)
      content
      (let [parts []]
        (each [_ block (ipairs (or content []))]
          (when (= block.type :text)
            (table.insert parts (or block.text ""))))
        (table.concat parts ""))))

(fn split-compound-id [id]
  "Tool call ids are stored canonically as `call_id|item_id` because the
   Responses API surfaces both. Returns (call-id item-id) where item-id is
   nil if no separator was present."
  (let [s (tostring (or id ""))
        sep (string.find s "|" 1 true)]
    (if sep
        (values (string.sub s 1 (- sep 1)) (string.sub s (+ sep 1)))
        (values s nil))))

(fn convert-user-message [m]
  {:role :user
   :content [{:type :input_text :text (text-of-content m.content)}]})

(fn convert-assistant-block [block msg-index]
  "Returns one Responses input item for an assistant content block, or nil
   to skip. Thinking blocks only round-trip when their :thinking-signature
   is the JSON-encoded ResponseReasoningItem we stored at end-of-stream;
   without it the API rejects the message."
  (if (= block.type :thinking)
      (let [sig block.thinking-signature]
        (if (and (= (type sig) :string)
                 (= (string.sub sig 1 1) "{"))
            (let [(ok? item) (pcall json.decode sig)]
              (if ok? item nil))
            nil))
      (= block.type :text)
      {:type :message
       :role :assistant
       :content [{:type :output_text
                  :text (or block.text "")
                  ;; cjson serializes empty Lua tables as `{}` not `[]`;
                  ;; the API rejects an object here.
                  :annotations json.empty-array}]
       :status :completed
       :id (.. "msg_" msg-index)}
      (= block.type :tool-call)
      (let [(call-id item-id) (split-compound-id block.id)
            args (json.encode (or block.arguments {}))
            out {:type :function_call
                 :call_id call-id
                 :name (or block.name "")
                 :arguments args}]
        (when (and item-id (not= item-id ""))
          (set out.id item-id))
        out)
      nil))

(fn convert-tool-result-message [m]
  (let [text-result (text-of-content m.content)
        (call-id _) (split-compound-id m.tool-call-id)]
    {:type :function_call_output
     :call_id call-id
     :output text-result}))

(fn pending-output [call-id]
  {:type :function_call_output
   :call_id call-id
   :output "[error] missing tool output; the prior tool call was interrupted before Fen recorded a result"})

(fn remove-pending! [pending call-id]
  (var removed? false)
  (var i 1)
  (while (<= i (length pending))
    (if (= (. pending i) call-id)
        (do (table.remove pending i)
            (set removed? true))
        (set i (+ i 1))))
  removed?)

(fn flush-pending! [out pending]
  (each [_ call-id (ipairs pending)]
    (table.insert out (pending-output call-id)))
  (while (> (length pending) 0)
    (table.remove pending)))

(fn convert-messages [messages]
  "Canonical Messages → Responses ResponseInput list. The system prompt does
   NOT go here — the caller puts it in the request body's `instructions`
   field. Assistant thinking blocks without a serialized
   ResponseReasoningItem signature are skipped, since the API requires a
   reasoning item shape we cannot reconstruct from raw text.

   Be defensive around persisted/replayed transcripts: OpenAI rejects any
   function_call without a matching function_call_output. Fen now writes
   synthetic tool results on cancellation, but older sessions may already
   contain orphaned tool calls. Synthesize missing outputs at message
   boundaries so those sessions can continue instead of getting stuck on
   repeated HTTP 400s."
  (let [out []
        pending []]
    (var msg-index 0)
    (each [_ m (ipairs (or messages []))]
      (when (and (> (length pending) 0) (not= m.role :tool-result))
        (flush-pending! out pending))
      (if (= m.role :user)
          (table.insert out (convert-user-message m))
          (= m.role :assistant)
          (each [_ block (ipairs (or m.content []))]
            (let [item (convert-assistant-block block msg-index)]
              (when item
                (table.insert out item)
                (when (= item.type :function_call)
                  (table.insert pending item.call_id)))))
          (= m.role :tool-result)
          (let [item (convert-tool-result-message m)]
            (remove-pending! pending item.call_id)
            (table.insert out item)))
      (set msg-index (+ msg-index 1)))
    (flush-pending! out pending)
    out))

(fn convert-tools [tools]
  "Canonical Tool[] → Responses tools[]. No `function:{...}` wrapper, unlike
   Chat Completions."
  (let [out []]
    (each [_ t (ipairs (or tools []))]
      (table.insert out
                    {:type :function
                     :name t.name
                     :description t.description
                     :parameters t.parameters
                     :strict json.null}))
    out))

;; ----------------------------------------------------------------
;; Inbound: Responses event → canonical
;; ----------------------------------------------------------------

(fn map-stop-reason [status]
  "Responses API ResponseStatus → canonical StopReason."
  (case status
    nil (values :stop nil)
    :completed (values :stop nil)
    :in_progress (values :stop nil)
    :queued (values :stop nil)
    :incomplete (values :length nil)
    :failed (values :error (.. "Response status: " (tostring status)))
    :cancelled (values :error (.. "Response status: " (tostring status)))
    _ (values :error (.. "Unhandled response status: " (tostring status)))))

(fn parse-streaming-json [s]
  "Best-effort parse: returns {} for nil/empty/invalid JSON during streaming.
   Mirrors pi-mono parseStreamingJson tolerance for in-flight JSON."
  (if (or (= s nil) (= s ""))
      {}
      (let [(ok? value) (pcall json.decode s)]
        (if (and ok? (= (type value) :table)) value {}))))

(fn new-stream-state [model]
  {:model model
   :content []
   :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
   :stop-reason :stop
   :error-message nil
   :response-id nil
   :current-item nil
   :current-block nil})

(fn current-content-index [state]
  (length state.content))

(fn finish-current-block! [state emit]
  (let [block state.current-block]
    (when block
      (let [idx (current-content-index state)]
        (if (= block.type :text)
            (when emit (emit {:type :text-end :content-index idx :content block.text}))
            (= block.type :thinking)
            (when emit (emit {:type :thinking-end :content-index idx :content block.thinking}))
            (= block.type :tool-call)
            (do
              (set block.partial-json nil)
              (when emit (emit {:type :tool-call-end :content-index idx :tool-call block}))))))
    (set state.current-block nil)
    (set state.current-item nil)))

(fn handle-output-item-added! [state item emit]
  (finish-current-block! state emit)
  (set state.current-item item)
  (if (= item.type :reasoning)
      (let [block (types.thinking-block {:thinking ""})]
        (table.insert state.content block)
        (set state.current-block block)
        (when emit (emit {:type :thinking-start
                          :content-index (current-content-index state)})))
      (= item.type :message)
      (let [block (types.text-block "")]
        (table.insert state.content block)
        (set state.current-block block)
        (when emit (emit {:type :text-start
                          :content-index (current-content-index state)})))
      (= item.type :function_call)
      (let [call-id (or item.call_id "")
            item-id (or item.id "")
            compound (if (and (not= call-id "") (not= item-id ""))
                         (.. call-id "|" item-id)
                         (if (not= call-id "") call-id item-id))
            initial-args (or item.arguments "")
            block (types.tool-call-block compound (or item.name "")
                                          (parse-streaming-json initial-args))]
        (set block.partial-json initial-args)
        (table.insert state.content block)
        (set state.current-block block)
        (when emit (emit {:type :tool-call-start
                          :content-index (current-content-index state)})))))

(fn handle-text-delta! [state delta emit]
  (let [block state.current-block]
    (when (and block (= block.type :text) (not= delta ""))
      (set block.text (.. block.text delta))
      (when emit
        (emit {:type :text-delta
               :content-index (current-content-index state)
               :delta delta})))))

(fn handle-thinking-delta! [state delta emit]
  (let [block state.current-block]
    (when (and block (= block.type :thinking) (not= delta ""))
      (set block.thinking (.. block.thinking delta))
      (when emit
        (emit {:type :thinking-delta
               :content-index (current-content-index state)
               :delta delta})))))

(fn handle-function-call-delta! [state delta emit]
  (let [block state.current-block]
    (when (and block (= block.type :tool-call) (not= delta ""))
      (set block.partial-json (.. (or block.partial-json "") delta))
      (set block.arguments (parse-streaming-json block.partial-json))
      (when emit
        (emit {:type :tool-call-delta
               :content-index (current-content-index state)
               :delta delta})))))

(fn handle-function-call-arguments-done! [state final-args emit]
  "Server gives us the canonical arguments string; emit a delta for any
   trailing content beyond what we've already streamed, then re-parse."
  (let [block state.current-block]
    (when (and block (= block.type :tool-call))
      (let [previous (or block.partial-json "")
            final (or final-args "")]
        (set block.partial-json final)
        (set block.arguments (parse-streaming-json final))
        (when (and emit
                   (>= (length final) (length previous))
                   (= (string.sub final 1 (length previous)) previous))
          (let [delta (string.sub final (+ (length previous) 1))]
            (when (not= delta "")
              (emit {:type :tool-call-delta
                     :content-index (current-content-index state)
                     :delta delta}))))))))

(fn join-text-parts [parts]
  (let [out []]
    (each [_ p (ipairs (or parts []))]
      (if (= p.type :output_text)
          (table.insert out (or p.text ""))
          (= p.type :refusal)
          (table.insert out (or p.refusal ""))))
    (table.concat out "")))

(fn join-summary-parts [parts]
  (let [out []]
    (each [_ p (ipairs (or parts []))]
      (table.insert out (or p.text "")))
    (table.concat out "\n\n")))

(fn finalize-reasoning-block! [block item]
  (let [joined (join-summary-parts item.summary)]
    (when (not= joined "")
      (set block.thinking joined)))
  (set block.thinking-signature (json.encode item)))

(fn finalize-message-block! [block item]
  (let [joined (join-text-parts item.content)]
    (when (not= joined "")
      (set block.text joined))))

(fn finalize-tool-call-block! [block item]
  (let [pj block.partial-json
        final (if (and pj (not= pj "")) pj (or item.arguments "{}"))]
    (set block.arguments (parse-streaming-json final))))

(fn handle-output-item-done! [state item emit]
  (let [block state.current-block]
    (if (and (= item.type :reasoning) block (= block.type :thinking))
        (finalize-reasoning-block! block item)
        (and (= item.type :message) block (= block.type :text))
        (finalize-message-block! block item)
        (and (= item.type :function_call) block (= block.type :tool-call))
        (finalize-tool-call-block! block item)))
  (finish-current-block! state emit))

(fn handle-completed! [state response]
  (when response
    (when response.id (set state.response-id response.id))
    (let [usage response.usage]
      (when usage
        (let [cached (or (?. usage :input_tokens_details :cached_tokens) 0)
              raw-input (or usage.input_tokens 0)
              input (if (> raw-input cached) (- raw-input cached) 0)]
          (set state.usage {: input
                            :output (or usage.output_tokens 0)
                            :cache-read cached
                            :cache-write 0
                            :total-tokens (or usage.total_tokens 0)}))))
    (let [(stop err) (map-stop-reason response.status)]
      (set state.stop-reason stop)
      (set state.error-message err))))

(fn handle-failed! [state response]
  (set state.stop-reason :error)
  (let [err (?. response :error)
        details (?. response :incomplete_details)
        reason (?. details :reason)]
    (set state.error-message
         (if err
             (.. (tostring (or err.code "unknown")) ": "
                 (tostring (or err.message "no message")))
             reason
             (.. "incomplete: " (tostring reason))
             "Unknown error (no error details in response)"))))

(fn handle-error-event! [state event]
  (set state.stop-reason :error)
  (set state.error-message
       (if event.code
           (.. "Error " (tostring event.code) ": "
               (tostring (or event.message "")))
           (tostring (or event.message "Unknown error")))))

(fn process-event! [state event emit]
  "Dispatch one decoded Responses event into the reducer state."
  (case (?. event :type)
    :response.created
    (set state.response-id (?. event :response :id))

    :response.output_item.added
    (handle-output-item-added! state event.item emit)

    :response.reasoning_summary_part.added
    nil

    :response.reasoning_summary_text.delta
    (handle-thinking-delta! state (or event.delta "") emit)

    :response.reasoning_summary_part.done
    (handle-thinking-delta! state "\n\n" emit)

    :response.content_part.added
    nil

    :response.output_text.delta
    (handle-text-delta! state (or event.delta "") emit)

    :response.refusal.delta
    (handle-text-delta! state (or event.delta "") emit)

    :response.function_call_arguments.delta
    (handle-function-call-delta! state (or event.delta "") emit)

    :response.function_call_arguments.done
    (handle-function-call-arguments-done! state (or event.arguments "") emit)

    :response.output_item.done
    (handle-output-item-done! state event.item emit)

    :response.completed
    (handle-completed! state event.response)

    :response.failed
    (handle-failed! state event.response)

    :error
    (handle-error-event! state event)

    _ nil))

(fn finalize-stream-state [state api provider emit]
  (finish-current-block! state emit)
  (when (and (= state.stop-reason :stop)
             (> (length (types.assistant-tool-calls {:content state.content})) 0))
    (set state.stop-reason :tool-use))
  (let [asst (types.assistant-message
               {: api : provider :model state.model
                :content state.content
                :usage state.usage
                :stop-reason state.stop-reason
                :error-message state.error-message})]
    (when emit
      (emit (if (= asst.stop-reason :error)
                {:type :error :message asst}
                {:type :done :message asst})))
    asst))

;; ----------------------------------------------------------------
;; Reasoning effort clamping (Codex per-model rules).
;; ----------------------------------------------------------------

(fn clamp-reasoning-effort [model effort]
  "Mirror pi-mono `openai-codex-responses.ts:357-367`: gpt-5.2/.3/.4/.5 do
   not accept :minimal (downgrade to :low); gpt-5.1-codex-mini caps at
   :high or :medium; gpt-5.1 does not accept :xhigh (downgrade to :high)."
  (let [m (tostring (or model ""))]
    (if (or (string.match m "^gpt%-5%.2") (string.match m "^gpt%-5%.3")
            (string.match m "^gpt%-5%.4") (string.match m "^gpt%-5%.5"))
        (if (= effort :minimal) :low effort)
        (string.match m "^gpt%-5%.1%-codex%-mini")
        (if (or (= effort :high) (= effort :xhigh)) :high :medium)
        (string.match m "^gpt%-5%.1")
        (if (= effort :xhigh) :high effort)
        effort)))

{: convert-messages
 : convert-tools
 : map-stop-reason
 : new-stream-state
 : process-event!
 : finalize-stream-state
 : finish-current-block!
 : clamp-reasoning-effort
 : split-compound-id
 : parse-streaming-json}
