;; Shared OpenAI-compatible Responses API request helpers and stream reducer.
;;
;; Both the vanilla OpenAI Responses provider (api.openai.com/v1/responses
;; with OPENAI_API_KEY) and the ChatGPT/Codex subscription provider
;; (chatgpt.com/backend-api/codex/responses with OAuth) use this module.
;; Endpoint, auth headers, API/provider identity, and Codex event aliases stay
;; with the provider extensions; OpenAI-compatible wire conversion and SSE
;; reduction live here.
;;
;; Mirrors pi-mono's `packages/ai/src/providers/openai-responses-shared.ts`,
;; simplified for fen's canonical types: no images, no
;; cost calculation, no service-tier pricing, no cross-provider id rewriting.

(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local http (require :fen.util.http))
(local sse (require :fen.util.sse))

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

;; @doc fen.extensions.provider_openai.openai_responses_shared.split-compound-id
;; kind: function
;; signature: (split-compound-id id) -> call-id, item-id|nil
;; summary: Split Fen's compound Responses tool-call id into call_id and item_id components for wire conversion.
;; tags: provider openai responses tools
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

;; @doc fen.extensions.provider_openai.openai_responses_shared.convert-messages
;; kind: function
;; signature: (convert-messages messages) -> [ResponseInputItem]
;; summary: Convert canonical transcript messages into Responses input items, preserving reasoning items and synthesizing missing tool outputs.
;; tags: provider openai responses messages
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

;; @doc fen.extensions.provider_openai.openai_responses_shared.convert-tools
;; kind: function
;; signature: (convert-tools tools) -> [ResponseTool]
;; summary: Convert canonical Tool descriptors into Responses function-tool declarations with strict set to JSON null.
;; tags: provider openai responses tools
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

;; @doc fen.extensions.provider_openai.openai_responses_shared.map-stop-reason
;; kind: function
;; signature: (map-stop-reason status) -> StopReason, error-message|nil
;; summary: Map Responses API response statuses onto canonical StopReason values and provider error messages.
;; tags: provider openai responses stop-reason
(fn table? [x]
  (= (type x) :table))

(fn field [x k]
  (when (table? x)
    (. x k)))

(fn array-or-empty [x]
  (if (table? x) x []))

(fn string-or-empty [x]
  (if (= (type x) :string) x ""))

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

;; @doc fen.extensions.provider_openai.openai_responses_shared.parse-streaming-json
;; kind: function
;; signature: (parse-streaming-json s) -> table
;; summary: Best-effort JSON parser for in-flight streamed tool arguments, returning an empty table until complete JSON is available.
;; tags: provider openai responses streaming
(fn parse-streaming-json [s]
  "Best-effort parse: returns {} for nil/empty/invalid JSON during streaming.
   Mirrors pi-mono parseStreamingJson tolerance for in-flight JSON."
  (if (or (= s nil) (= s ""))
      {}
      (let [(ok? value) (pcall json.decode s)]
        (if (and ok? (= (type value) :table)) value {}))))

;; @doc fen.extensions.provider_openai.openai_responses_shared.new-stream-state
;; kind: function
;; signature: (new-stream-state model) -> table
;; summary: Initialize the mutable reducer state used while folding Responses SSE events into canonical assistant content.
;; tags: provider openai responses streaming
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

;; @doc fen.extensions.provider_openai.openai_responses_shared.finish-current-block!
;; kind: function
;; signature: (finish-current-block! state emit) -> nil
;; summary: Close the active text/thinking/tool-call block, emit the matching end event, and clear current item pointers.
;; tags: provider openai responses streaming
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
  (when (table? item)
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
        (let [call-id (string-or-empty item.call_id)
              item-id (string-or-empty item.id)
              compound (if (and (not= call-id "") (not= item-id ""))
                           (.. call-id "|" item-id)
                           (if (not= call-id "") call-id item-id))
              initial-args (string-or-empty item.arguments)
              block (types.tool-call-block compound (string-or-empty item.name)
                                            (parse-streaming-json initial-args))]
          (set block.partial-json initial-args)
          (table.insert state.content block)
          (set state.current-block block)
          (when emit (emit {:type :tool-call-start
                            :content-index (current-content-index state)}))))))

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
  (let [block state.current-block
        text (string-or-empty delta)]
    (when (and block (= block.type :tool-call) (not= text ""))
      (set block.partial-json (.. (or block.partial-json "") text))
      (set block.arguments (parse-streaming-json block.partial-json))
      (when emit
        (emit {:type :tool-call-delta
               :content-index (current-content-index state)
               :delta text})))))

(fn handle-function-call-arguments-done! [state final-args emit]
  "Server gives us the canonical arguments string; emit a delta for any
   trailing content beyond what we've already streamed, then re-parse."
  (let [block state.current-block]
    (when (and block (= block.type :tool-call))
      (let [previous (or block.partial-json "")
            final (string-or-empty final-args)]
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
    (each [_ p (ipairs (array-or-empty parts))]
      (when (table? p)
        (if (= p.type :output_text)
            (table.insert out (string-or-empty p.text))
            (= p.type :refusal)
            (table.insert out (string-or-empty p.refusal)))))
    (table.concat out "")))

(fn join-summary-parts [parts]
  (let [out []]
    (each [_ p (ipairs (array-or-empty parts))]
      (when (table? p)
        (table.insert out (string-or-empty p.text))))
    (table.concat out "\n\n")))

(fn finalize-reasoning-block! [block item]
  (let [joined (join-summary-parts (field item :summary))]
    (when (not= joined "")
      (set block.thinking joined)))
  (when (table? item)
    (set block.thinking-signature (json.encode item))))

(fn finalize-message-block! [block item]
  (let [joined (join-text-parts (field item :content))]
    (when (not= joined "")
      (set block.text joined))))

(fn finalize-tool-call-block! [block item]
  (let [pj block.partial-json
        item-args (string-or-empty (field item :arguments))
        final (if (and pj (not= pj "")) pj item-args)]
    (set block.arguments (parse-streaming-json final))))

(fn handle-output-item-done! [state item emit]
  (when (table? item)
    (let [block state.current-block]
      (if (and (= item.type :reasoning) block (= block.type :thinking))
          (finalize-reasoning-block! block item)
          (and (= item.type :message) block (= block.type :text))
          (finalize-message-block! block item)
          (and (= item.type :function_call) block (= block.type :tool-call))
          (finalize-tool-call-block! block item))))
  (finish-current-block! state emit))

(fn number-or-zero [x]
  (if (= (type x) :number) x 0))

(fn handle-completed! [state response]
  (when (table? response)
    (when response.id (set state.response-id response.id))
    (let [usage (field response :usage)]
      (when (table? usage)
        (let [cached (number-or-zero (field (field usage :input_tokens_details) :cached_tokens))
              raw-input (number-or-zero usage.input_tokens)
              input (if (> raw-input cached) (- raw-input cached) 0)]
          (set state.usage {: input
                            :output (number-or-zero usage.output_tokens)
                            :cache-read cached
                            :cache-write 0
                            :total-tokens (number-or-zero usage.total_tokens)}))))
    (let [(stop err) (map-stop-reason response.status)]
      (set state.stop-reason stop)
      (set state.error-message err))))

(fn handle-failed! [state response]
  (set state.stop-reason :error)
  (let [err (field response :error)
        details (field response :incomplete_details)
        reason (field details :reason)]
    (set state.error-message
         (if (table? err)
             (.. (tostring (or err.code "unknown")) ": "
                 (tostring (or err.message "no message")))
             reason
             (.. "incomplete: " (tostring reason))
             "Unknown error (no error details in response)"))))

(fn handle-error-event! [state event]
  (set state.stop-reason :error)
  (let [code (field event :code)
        message (field event :message)]
    (set state.error-message
         (if code
             (.. "Error " (tostring code) ": "
                 (tostring (or message "")))
             (tostring (or message "Unknown error"))))))

;; @doc fen.extensions.provider_openai.openai_responses_shared.process-event!
;; kind: function
;; signature: (process-event! state event emit) -> nil
;; summary: Dispatch one decoded Responses SSE event into reducer state, updating content, usage, errors, and delta callbacks.
;; tags: provider openai responses streaming
(fn process-event! [state event emit]
  "Dispatch one decoded Responses event into the reducer state.
   Unknown or malformed events are ignored instead of escaping callback
   errors from provider streaming code."
  (case (field event :type)
    :response.created
    (set state.response-id (field (field event :response) :id))

    :response.output_item.added
    (handle-output-item-added! state (field event :item) emit)

    :response.reasoning_summary_part.added
    nil

    :response.reasoning_summary_text.delta
    (handle-thinking-delta! state (string-or-empty (field event :delta)) emit)

    :response.reasoning_summary_part.done
    (handle-thinking-delta! state "\n\n" emit)

    :response.content_part.added
    nil

    :response.output_text.delta
    (handle-text-delta! state (string-or-empty (field event :delta)) emit)

    :response.refusal.delta
    (handle-text-delta! state (string-or-empty (field event :delta)) emit)

    :response.function_call_arguments.delta
    (handle-function-call-delta! state (field event :delta) emit)

    :response.function_call_arguments.done
    (handle-function-call-arguments-done! state (field event :arguments) emit)

    :response.output_item.done
    (handle-output-item-done! state (field event :item) emit)

    :response.completed
    (handle-completed! state (field event :response))

    :response.failed
    (handle-failed! state (field event :response))

    :error
    (handle-error-event! state event)

    _ nil))

;; @doc fen.extensions.provider_openai.openai_responses_shared.finalize-stream-state
;; kind: function
;; signature: (finalize-stream-state state api provider emit) -> AssistantMessage
;; summary: Finalize Responses reducer state into a canonical assistant message and emit the terminal done/error event.
;; tags: provider openai responses streaming
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
;; Shared Responses request / SSE helpers
;; ----------------------------------------------------------------

(var clamp-reasoning-effort nil)

(fn ends-with? [s suffix]
  (let [n (length suffix)]
    (and (>= (length s) n)
         (= (string.sub s (- (length s) n -1)) suffix))))

;; @doc fen.extensions.provider_openai.openai_responses_shared.build-url
;; kind: function
;; signature: (build-url base-url responses-path) -> string
;; summary: Normalize an OpenAI-compatible base URL into a Responses endpoint while preserving already-qualified URLs.
;; tags: provider openai responses http
(fn build-url [base-url responses-path]
  (if (ends-with? base-url responses-path)
      base-url
      (.. base-url responses-path)))

;; @doc fen.extensions.provider_openai.openai_responses_shared.build-body
;; kind: function
;; signature: (build-body model context max-tokens options) -> table
;; summary: Build a streaming Responses request body from canonical context, provider options, tools, reasoning settings, and prompt cache keys.
;; tags: provider openai responses request
(fn build-body [model context max-tokens options]
  "Build a Responses request body. The system prompt rides in `instructions`,
   not in `input`. `options` is the flat per-call options table — it
   carries provider knobs like `:reasoning-effort`, `:verbosity`,
   `:include`, `:service-tier`, `:prompt-cache-key`, and `:temperature`."
  (let [opts (or options {})
        body {: model
              :store false
              :stream true
              :input (convert-messages context.messages)}]
    (when (and context.system-prompt (not= context.system-prompt ""))
      (set body.instructions context.system-prompt))
    (when (and context.tools (> (length context.tools) 0))
      (set body.tools (convert-tools context.tools))
      (set body.tool_choice :auto)
      (set body.parallel_tool_calls true))
    ;; The Codex backend rejects `max_output_tokens` ("Unsupported parameter")
    ;; even though vanilla /v1/responses accepts it; the Codex provider sets
    ;; opts.skip-max-output-tokens? so we omit it.
    (when (and max-tokens (not opts.skip-max-output-tokens?))
      (set body.max_output_tokens max-tokens))
    (when opts.temperature
      (set body.temperature opts.temperature))
    (when opts.reasoning-effort
      (set body.reasoning
           {:effort (clamp-reasoning-effort model opts.reasoning-effort)
            :summary :auto}))
    (when opts.verbosity
      (set body.text {:verbosity opts.verbosity}))
    (when (and opts.include (> (length opts.include) 0))
      (set body.include opts.include))
    (when opts.service-tier
      (set body.service_tier opts.service-tier))
    (when opts.prompt-cache-key
      (set body.prompt_cache_key opts.prompt-cache-key))
    body))

(fn request-headers [api-key]
  (let [headers {:accept "text/event-stream"
                 :content-type "application/json"}]
    (when (and api-key (not= api-key ""))
      (set headers.authorization (.. "Bearer " api-key)))
    headers))

;; @doc fen.extensions.provider_openai.openai_responses_shared.make-stream-pipeline
;; kind: function
;; signature: (make-stream-pipeline model on-event event-mapper) -> state, parser, parser-error
;; summary: Create the SSE parser and shared Responses stream reducer state for one streaming request, with optional event mapping.
;; tags: provider openai responses streaming
(fn make-stream-pipeline [model on-event event-mapper]
  "Build a fresh (state parser parser-error) tuple for one streaming POST.
   `event-mapper` is optional (used by the Codex subscription provider to
   alias `response.done` / `response.incomplete` to `response.completed`)."
  (let [state (new-stream-state model)
        parser-error {:message nil}
        parser (sse.new-parser
                 (fn [ev]
                   (when (and (not parser-error.message)
                              (not= ev.data nil)
                              (not= ev.data "")
                              (not= ev.data "[DONE]"))
                     (let [(ok? decoded) (pcall json.decode ev.data)]
                       (if (not ok?)
                           (set parser-error.message decoded)
                           (let [mapped (if event-mapper
                                            (event-mapper decoded)
                                            decoded)]
                             (when mapped
                               (process-event! state mapped on-event))))))))]
    (values state parser parser-error)))

;; @doc fen.extensions.provider_openai.openai_responses_shared.build-request-opts
;; kind: function
;; signature: (build-request-opts model context options on-chunk ?headers-override ?url-override default-base-url responses-path) -> table
;; summary: Assemble fen.util.http options for a streaming OpenAI-compatible Responses POST.
;; tags: provider openai responses http
(fn build-request-opts [model context options on-chunk ?headers-override ?url-override default-base-url responses-path]
  (let [opts (or options {})
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url default-base-url)
        url (or ?url-override (build-url base-url responses-path))
        max-tokens (or opts.max-tokens 16384)
        body (build-body model context max-tokens opts)]
    {:method :POST
     : url
     :headers (or ?headers-override (request-headers api-key))
     :body (json.encode body)
     :timeout-ms (or opts.timeout-ms 600000)
     :connect-timeout-ms (or opts.connect-timeout-ms 30000)
     : on-chunk}))

;; @doc fen.extensions.provider_openai.openai_responses_shared.finalize-stream
;; kind: function
;; signature: (finalize-stream state parser parser-error api provider model resp on-event) -> AssistantMessage
;; summary: Finish a Responses SSE stream, preserving the calling provider's canonical API/provider identity.
;; tags: provider openai responses streaming
(fn finalize-stream [state parser parser-error api provider model resp on-event]
  (when (not resp.error) (parser.finish))
  (if resp.error
      (let [asst (types.assistant-error api provider model resp.error)]
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (not= parser-error.message nil)
      (let [asst (types.assistant-error api provider model parser-error.message)]
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (or (< resp.status 200) (>= resp.status 300))
      (let [asst (types.assistant-error api provider model
                                        (.. "HTTP " resp.status ": " resp.body))]
        (log.error (.. "http " resp.status ": " resp.body))
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (finalize-stream-state state api provider on-event)))

;; ----------------------------------------------------------------
;; Reasoning effort clamping (Codex per-model rules).
;; ----------------------------------------------------------------

;; @doc fen.extensions.provider_openai.openai_responses_shared.clamp-reasoning-effort
;; kind: function
;; signature: (clamp-reasoning-effort model effort) -> keyword
;; summary: Apply Codex/OpenAI per-model reasoning-effort limits so request bodies avoid unsupported effort values.
;; tags: provider openai codex reasoning
(set clamp-reasoning-effort
  (fn [model effort]
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
          effort))))

{: build-url
 : build-body
 : build-request-opts
 : make-stream-pipeline
 : finalize-stream
 : convert-messages
 : convert-tools
 : map-stop-reason
 : new-stream-state
 : process-event!
 : finalize-stream-state
 : finish-current-block!
 : clamp-reasoning-effort
 : split-compound-id
 : parse-streaming-json}
