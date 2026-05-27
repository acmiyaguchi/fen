;; OpenAI Chat Completions provider.
;;
;; Mirrors pi-mono's `packages/ai/src/providers/openai-completions.ts`
;; surface: convert-messages, convert-tools, map-stop-reason, parse-response,
;; complete (non-streaming POST). The agent loop sees only canonical
;; `core.types` shapes; everything OpenAI-specific lives here.
;;
;; Note: official OpenAI Chat Completions does not return thinking content even
;; for the reasoning model family. Some OpenAI-compatible providers expose
;; reasoning via non-standard fields; this provider preserves those fields as
;; canonical thinking blocks when present.

(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local http (require :fen.util.http))
(local sse (require :fen.util.sse))
(local retry (require :fen.core.llm.retry))

(local API :openai-completions)
(local PROVIDER :openai)
(local DEFAULT-BASE-URL "https://api.openai.com/v1")
(local CHAT-COMPLETIONS-PATH "/chat/completions")
;; Bound how long the request can hang. Reasoning models can think for
;; minutes, so the overall cap is generous; the connect cap fails fast on
;; bad endpoints. Override per-call via options :timeout-ms / :connect-timeout-ms.
(local DEFAULT-TIMEOUT-MS 600000)
(local DEFAULT-CONNECT-TIMEOUT-MS 30000)
(local REASONING-FIELDS [:reasoning_content :reasoning :reasoning_text])

(fn ends-with? [s suffix]
  (let [n (length suffix)]
    (and (>= (length s) n)
         (= (string.sub s (- (length s) n -1)) suffix))))

;; @doc fen.extensions.provider_openai.openai_completions.build-url
;; kind: function
;; signature: (build-url base-url) -> string
;; summary: Normalize an OpenAI-compatible base URL into a Chat Completions endpoint while preserving fully-qualified legacy endpoints.
;; tags: provider openai completions http
(fn build-url [base-url]
  "Mirror pi-mono's models.json convention: `baseUrl` is the v1 root
   (`http://localhost:11434/v1`); we append `/chat/completions`. If the
   caller passed a fully-qualified completions URL (legacy), respect it."
  (if (ends-with? base-url CHAT-COMPLETIONS-PATH)
      base-url
      (.. base-url CHAT-COMPLETIONS-PATH)))

;; ----------------------------------------------------------------
;; Outbound: canonical → OpenAI wire
;; ----------------------------------------------------------------

(fn text-of-content [content]
  "Concat all text blocks of an assistant/tool-result content array."
  (if (= (type content) :string)
      content
      (let [parts []]
        (each [_ block (ipairs (or content []))]
          (when (= block.type :text)
            (table.insert parts (or block.text ""))))
        (table.concat parts ""))))

(fn known-reasoning-field? [field]
  (var known? false)
  (each [_ name (ipairs REASONING-FIELDS)]
    (when (= field name)
      (set known? true)))
  known?)

(fn reasoning-content-for-echo [content]
  "If an assistant thinking block came from a known OpenAI-compatible reasoning
   field, echo non-empty thinking back under that same field on the next turn."
  (let [parts []]
    (var field nil)
    (each [_ block (ipairs (or content []))]
      (when (and (= block.type :thinking)
                 (= (type block.thinking) :string)
                 (not= block.thinking ""))
        (when (and (= field nil)
                   block.thinking-signature
                   (known-reasoning-field? block.thinking-signature))
          (set field block.thinking-signature))
        (table.insert parts block.thinking)))
    (if field
        (values field (table.concat parts "\n"))
        (values nil nil))))

(fn extract-tool-calls [content]
  "Collect ToolCall blocks from an assistant content array, in OpenAI shape."
  (let [out []]
    (each [_ block (ipairs (or content []))]
      (when (= block.type :tool-call)
        (table.insert out
                      {:id block.id
                       :type :function
                       :function {:name block.name
                                  :arguments (json.encode (or block.arguments {}))}})))
    out))

(fn convert-message [m echo-reasoning?]
  (if (= m.role :user)
      {:role :user :content (text-of-content m.content)}

      (= m.role :assistant)
      (let [text (text-of-content m.content)
            tool-calls (extract-tool-calls m.content)
            (reasoning-field reasoning-text) (reasoning-content-for-echo m.content)
            out {:role :assistant}]
        ;; OpenAI requires content OR tool_calls. Null content is only valid
        ;; when tool_calls is present; otherwise send empty string.
        (set out.content
             (if (and (= text "") (> (length tool-calls) 0)) json.null text))
        (when (and echo-reasoning? reasoning-field)
          (tset out reasoning-field reasoning-text))
        (when (> (length tool-calls) 0)
          (set out.tool_calls tool-calls))
        out)

      (= m.role :tool-result)
      {:role :tool
       :tool_call_id m.tool-call-id
       :content (text-of-content m.content)}

      (error (.. "openai_completions: unhandled message role: " (tostring m.role)))))

(fn pending-tool-message [tool-call-id]
  {:role :tool
   :tool_call_id tool-call-id
   :content "[error] missing tool output; the prior tool call was interrupted before Fen recorded a result"})

(fn remove-pending! [pending tool-call-id]
  (var i 1)
  (while (<= i (length pending))
    (if (= (. pending i) tool-call-id)
        (table.remove pending i)
        (set i (+ i 1)))))

(fn flush-pending! [out pending]
  (each [_ tool-call-id (ipairs pending)]
    (table.insert out (pending-tool-message tool-call-id)))
  (while (> (length pending) 0)
    (table.remove pending)))

(fn remember-tool-calls! [pending m]
  (each [_ block (ipairs (or m.content []))]
    (when (= block.type :tool-call)
      (table.insert pending block.id))))

;; @doc fen.extensions.provider_openai.openai_completions.convert-messages
;; kind: function
;; signature: (convert-messages messages system-prompt compat) -> [WireMessage]
;; summary: Convert canonical messages and optional system prompt into OpenAI Chat Completions wire messages, synthesizing errors for orphaned tool calls.
;; tags: provider openai completions messages
(fn convert-messages [messages system-prompt compat]
  "Canonical Messages + optional system prompt → OpenAI ChatCompletionMessageParam[].
   If a replayed transcript contains an orphaned assistant tool call from an
   older interrupted run, synthesize a tool error message instead of sending
   invalid history that the provider rejects."
  (let [out []
        pending []
        echo-reasoning? (or (?. compat :echoReasoningFields)
                            (?. compat :thinkingFormat))]
    (when (and system-prompt (not= system-prompt ""))
      (table.insert out {:role :system :content system-prompt}))
    (each [_ m (ipairs (or messages []))]
      (when (and (> (length pending) 0) (not= m.role :tool-result))
        (flush-pending! out pending))
      (table.insert out (convert-message m echo-reasoning?))
      (if (= m.role :assistant)
          (remember-tool-calls! pending m)
          (= m.role :tool-result)
          (remove-pending! pending m.tool-call-id)))
    (flush-pending! out pending)
    out))

;; @doc fen.extensions.provider_openai.openai_completions.convert-tools
;; kind: function
;; signature: (convert-tools tools) -> [WireTool]
;; summary: Convert canonical Tool descriptors into OpenAI Chat Completions function-tool declarations.
;; tags: provider openai completions tools
(fn convert-tools [tools]
  "Canonical Tool[] → OpenAI tool-function[]."
  (let [out []]
    (each [_ t (ipairs (or tools []))]
      (table.insert out
                    {:type :function
                     :function {:name t.name
                                :description t.description
                                :parameters t.parameters}}))
    out))

;; ----------------------------------------------------------------
;; Inbound: OpenAI wire → canonical
;; ----------------------------------------------------------------

;; @doc fen.extensions.provider_openai.openai_completions.map-stop-reason
;; kind: function
;; signature: (map-stop-reason reason) -> StopReason, error-message|nil
;; summary: Map OpenAI finish_reason values onto canonical StopReason values, returning error text for provider-side stops.
;; tags: provider openai completions stop-reason
(fn map-stop-reason [reason]
  "OpenAI finish_reason → canonical StopReason. Mirrors pi-mono
   openai-completions.ts:989-1012."
  (case reason
    nil (values :stop nil)
    :stop (values :stop nil)
    :end (values :stop nil)
    :length (values :length nil)
    :tool_calls (values :tool-use nil)
    :function_call (values :tool-use nil)
    :content_filter (values :error "Provider finish_reason: content_filter")
    :network_error (values :error "Provider finish_reason: network_error")
    _ (values :error (.. "Provider finish_reason: " (tostring reason)))))

(fn decode-tool-arguments [args]
  "OpenAI tool_calls.function.arguments is a JSON-encoded string per spec, but
   some OpenAI-compatible servers (notably some Ollama versions) return a
   parsed object instead. Accept either; on parse failure of a string, return
   the empty table and log."
  (if (or (= args nil) (= args ""))
      {}
      (= (type args) :table)
      args
      (let [(ok? value) (pcall json.decode args)]
        (if ok? value
            (do (log.warn (.. "openai_completions: bad tool args JSON: "
                              (tostring value)))
                {})))))

(fn first-reasoning-field [msg]
  "Find the first non-empty non-standard reasoning field on an assistant
   message. Some providers duplicate the same text across multiple fields."
  (var field nil)
  (var value nil)
  (when msg
    (each [_ candidate (ipairs REASONING-FIELDS)]
      (let [v (. msg candidate)]
        (when (and (= field nil) (= (type v) :string) (not= v ""))
          (set field candidate)
          (set value v)))))
  (values field value))

;; @doc fen.extensions.provider_openai.openai_completions.parse-response
;; kind: function
;; signature: (parse-response resp model) -> AssistantMessage
;; summary: Parse a non-streaming OpenAI Chat Completions response into canonical assistant content, usage, tool calls, and stop reason.
;; tags: provider openai completions parse
(fn parse-response [resp model]
  "OpenAI response → canonical AssistantMessage."
  (let [choice (?. resp :choices 1)
        msg (?. choice :message)
        finish (?. choice :finish_reason)
        (stop-reason error-message) (map-stop-reason finish)
        usage (or resp.usage {})
        content []
        (reasoning-field reasoning-value) (first-reasoning-field msg)]
    (when reasoning-field
      (table.insert content
                    (types.thinking-block
                      {:thinking reasoning-value
                       :thinking-signature reasoning-field})))
    ;; OpenAI returns `content: null` (cjson.null lightuserdata) when the
    ;; model only emits tool_calls. Guard on `string` so a userdata sentinel
    ;; never sneaks into a text-block — it would crash table.concat on the
    ;; next turn through text-of-content.
    (when (and msg (= (type msg.content) :string) (not= msg.content ""))
      (table.insert content (types.text-block msg.content)))
    (when (and msg msg.tool_calls)
      (each [_ tc (ipairs msg.tool_calls)]
        (table.insert content
                      (types.tool-call-block
                        tc.id
                        (?. tc :function :name)
                        (decode-tool-arguments (?. tc :function :arguments))))))
    (types.assistant-message
      {:api API :provider PROVIDER : model
       : content
       :usage {:input (or usage.prompt_tokens 0)
               :output (or usage.completion_tokens 0)
               :cache-read (or (?. usage :prompt_tokens_details :cached_tokens) 0)
               :cache-write 0
               :total-tokens (or usage.total_tokens 0)}
       : stop-reason
       : error-message})))

;; ----------------------------------------------------------------
;; HTTP transport
;; ----------------------------------------------------------------

(fn compat-thinking-enabled? [compat]
  (let [explicit (?. compat :enableThinking)]
    (if (not= explicit nil) explicit true)))

(fn apply-thinking-compat [body compat]
  "Enable common OpenAI-compatible thinking knobs when models.json sets
   compat.thinkingFormat. Default to enabled because selecting a format is an
   explicit provider opt-in; compat.enableThinking=false disables it."
  (let [fmt (?. compat :thinkingFormat)]
    (when fmt
      (let [enabled? (compat-thinking-enabled? compat)]
        (if (or (= fmt :zai) (= fmt :qwen))
            (set body.enable_thinking enabled?)
            (= fmt :qwen-chat-template)
            (set body.chat_template_kwargs
                 {:enable_thinking enabled? :preserve_thinking true})
            (= fmt :deepseek)
            (set body.thinking {:type (if enabled? :enabled :disabled)})
            (= fmt :openrouter)
            (set body.reasoning (if enabled? {:effort :medium} {:effort :none}))))))
  body)

(fn parallel-tool-calls? [options]
  "Provider option normalized across providers. Defaults on; only explicit
   `:parallel-tool-calls false` disables it."
  (let [v (?. options :parallel-tool-calls)]
    (if (= v nil) true v)))

;; @doc fen.extensions.provider_openai.openai_completions.build-body
;; kind: function
;; signature: (build-body model context max-tokens compat options) -> table
;; summary: Build the Chat Completions request body, applying models.json compat knobs for max-token fields, thinking formats, and parallel tools.
;; tags: provider openai completions request
(fn build-body [model context max-tokens compat options]
  "Build the chat-completions request body. `compat` is an optional table of
   per-provider OpenAI-compat overrides (see `core.llm.models`). Supports
   `:maxTokensField` and a small `:thinkingFormat` set for OpenAI-compatible
   reasoning providers. `options.parallel-tool-calls` controls OpenAI's
   explicit `parallel_tool_calls` request flag."
  (let [max-field (or (?. compat :maxTokensField) :max_completion_tokens)
        body {: model
              :messages (convert-messages context.messages context.system-prompt compat)}]
    (tset body max-field (or max-tokens 16384))
    (apply-thinking-compat body compat)
    (when (and options options.reasoning-effort)
      (set body.reasoning_effort options.reasoning-effort))
    (when (and context.tools (> (length context.tools) 0))
      (set body.tools (convert-tools context.tools))
      (set body.tool_choice :auto)
      (set body.parallel_tool_calls (parallel-tool-calls? options)))
    body))

(fn request-headers [api-key streaming?]
  (let [headers {:content-type "application/json"}]
    (when streaming? (set headers.accept "text/event-stream"))
    ;; Skip the Authorization header entirely when there's no key.
    ;; Ollama and other auth-less local servers ignore Bearer tokens but
    ;; sending an empty `Authorization: Bearer ` is at best noise and at
    ;; worst makes some servers reject the request.
    (when (and api-key (not= api-key ""))
      (set headers.authorization (.. "Bearer " api-key)))
    headers))

(fn build-request-opts [model context options ?on-chunk]
  "Assemble a fen.util.http opts table for a Chat Completions POST. When
   ?on-chunk is provided, the request is configured for streaming
   (`stream:true`, `Accept: text/event-stream`)."
  (let [opts (or options {})
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (build-url base-url)
        max-tokens (or opts.max-tokens 16384)
        compat opts.compat
        body (build-body model context max-tokens compat opts)
        streaming? (not= ?on-chunk nil)]
    (when streaming?
      (set body.stream true)
      (when (= (?. compat :supportsUsageInStreaming) true)
        (set body.stream_options {:include_usage true})))
    {:method :POST
     : url
     :headers (request-headers api-key streaming?)
     :body (json.encode body)
     :timeout-ms (or opts.timeout-ms DEFAULT-TIMEOUT-MS)
     :connect-timeout-ms (or opts.connect-timeout-ms DEFAULT-CONNECT-TIMEOUT-MS)
     :on-chunk ?on-chunk}))

(fn response->assistant [model resp]
  (if resp.error
      (do (log.error (.. "http transport failed: " resp.error))
          (types.assistant-error API PROVIDER model resp.error))
      (let [raw resp.body
            (decoded? value) (pcall json.decode raw)]
        (if (not decoded?)
            (do (log.error (.. "json decode failed: " (tostring value) " body=" raw))
                (types.assistant-error API PROVIDER model value))
            (if (or (< resp.status 200) (>= resp.status 300))
                (do (log.error (.. "http " resp.status ": " raw))
                    (types.assistant-error API PROVIDER model
                      (.. "HTTP " resp.status ": " raw)))
                (parse-response value model))))))

(fn new-stream-state [model]
  {:model model
   :content []
   :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
   :stop-reason :stop
   :error-message nil
   :current-block nil
   ;; True once a choice carries a finish_reason. A 200 stream that closes
   ;; without one is incomplete, not an empty :stop success.
   :saw-terminal? false})

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
              (set block.arguments (decode-tool-arguments (or block.partial-args "{}")))
              (set block.partial-args nil)
              (set block.stream-index nil)
              (when emit (emit {:type :tool-call-end :content-index idx :tool-call block}))))))
    (set state.current-block nil)))

(fn ensure-text-block! [state emit]
  (when (or (not state.current-block) (not= state.current-block.type :text))
    (finish-current-block! state emit)
    (let [block (types.text-block "")]
      (table.insert state.content block)
      (set state.current-block block)
      (when emit (emit {:type :text-start :content-index (current-content-index state)}))))
  state.current-block)

(fn ensure-thinking-block! [state field emit]
  (when (or (not state.current-block) (not= state.current-block.type :thinking))
    (finish-current-block! state emit)
    (let [block (types.thinking-block {:thinking "" :thinking-signature field})]
      (table.insert state.content block)
      (set state.current-block block)
      (when emit (emit {:type :thinking-start :content-index (current-content-index state)}))))
  state.current-block)

(fn find-tool-block [state stream-index id]
  (var found nil)
  (each [_ block (ipairs state.content)]
    (when (and (= block.type :tool-call)
               (or (and (not= stream-index nil) (= block.stream-index stream-index))
                   (and id (not= id "") (= block.id id))))
      (set found block)))
  found)

(fn ensure-tool-block! [state tool-call emit]
  (let [stream-index tool-call.index
        id tool-call.id
        fn-shape tool-call.function
        existing (find-tool-block state stream-index id)]
    (if existing
        (do
          (when (not= state.current-block existing)
            (finish-current-block! state emit)
            (set state.current-block existing))
          (when (and (or (= existing.id nil) (= existing.id "")) id)
            (set existing.id id))
          (when (and (or (= existing.name nil) (= existing.name "")) (?. fn-shape :name))
            (set existing.name fn-shape.name))
          (when (and (= existing.stream-index nil) (not= stream-index nil))
            (set existing.stream-index stream-index))
          existing)
        (do
          (finish-current-block! state emit)
          (let [block (types.tool-call-block (or id "") (or (?. fn-shape :name) "") {})]
            (set block.partial-args "")
            (when (not= stream-index nil) (set block.stream-index stream-index))
            (table.insert state.content block)
            (set state.current-block block)
            (when emit (emit {:type :tool-call-start :content-index (current-content-index state)}))
            block)))))

(fn update-stream-usage! [state usage]
  (when usage
    (let [cached (or (?. usage :prompt_tokens_details :cached_tokens) 0)]
      (set state.usage {:input (or usage.prompt_tokens 0)
                        :output (or usage.completion_tokens 0)
                        :cache-read cached
                        :cache-write 0
                        :total-tokens (or usage.total_tokens 0)}))))

;; @doc fen.extensions.provider_openai.openai_completions.process-stream-chunk!
;; kind: function
;; signature: (process-stream-chunk! state chunk emit) -> state
;; summary: Fold one decoded streaming ChatCompletionChunk into stream state and emit text, thinking, and tool-call deltas.
;; tags: provider openai completions streaming
(fn process-stream-chunk! [state chunk emit]
  "Consume one decoded OpenAI ChatCompletionChunk-like table."
  (update-stream-usage! state chunk.usage)
  (let [choice (?. chunk :choices 1)]
    (when choice
      (when (?. choice :usage)
        (update-stream-usage! state choice.usage))
      (when choice.finish_reason
        (set state.saw-terminal? true)
        (let [(stop err) (map-stop-reason choice.finish_reason)]
          (set state.stop-reason stop)
          (set state.error-message err)))
      (let [delta choice.delta]
        (when delta
          (when (and (= (type delta.content) :string) (not= delta.content ""))
            (let [block (ensure-text-block! state emit)]
              (set block.text (.. block.text delta.content))
              (when emit
                (emit {:type :text-delta
                       :content-index (current-content-index state)
                       :delta delta.content}))))
          (var reasoning-field nil)
          (var reasoning-value nil)
          (each [_ field (ipairs REASONING-FIELDS)]
            (let [v (. delta field)]
              (when (and (= reasoning-field nil)
                         (= (type v) :string)
                         (not= v ""))
                (set reasoning-field field)
                (set reasoning-value v))))
          (when reasoning-field
            (let [block (ensure-thinking-block! state reasoning-field emit)]
              (set block.thinking (.. block.thinking reasoning-value))
              (when emit
                (emit {:type :thinking-delta
                       :content-index (current-content-index state)
                       :delta reasoning-value}))))
          (when delta.tool_calls
            (each [_ tc (ipairs delta.tool_calls)]
              (let [block (ensure-tool-block! state tc emit)
                    arg-delta (or (?. tc :function :arguments) "")]
                (when (and (?. tc :function :name) (= block.name ""))
                  (set block.name tc.function.name))
                (when (and tc.id (= block.id ""))
                  (set block.id tc.id))
                (when (not= arg-delta "")
                  (set block.partial-args (.. (or block.partial-args "") arg-delta))
                  (when emit
                    (emit {:type :tool-call-delta
                           :content-index (current-content-index state)
                           :delta arg-delta}))))))))))
  state)

;; @doc fen.extensions.provider_openai.openai_completions.finalize-stream-state
;; kind: function
;; signature: (finalize-stream-state state emit) -> AssistantMessage
;; summary: Close the streaming content block state, infer tool-use stops, emit the terminal event, and return the canonical assistant message.
;; tags: provider openai completions streaming
(fn finalize-stream-state [state emit]
  (finish-current-block! state emit)
  (when (and (= state.stop-reason :stop)
             (> (length (types.assistant-tool-calls {:content state.content})) 0))
    (set state.stop-reason :tool-use))
  (let [asst (types.assistant-message
               {:api API :provider PROVIDER :model state.model
                :content state.content
                :usage state.usage
                :stop-reason state.stop-reason
                :error-message state.error-message})]
    (when emit
      (emit (if (= asst.stop-reason :error)
                {:type :error :message asst}
                {:type :done :message asst})))
    asst))

(fn make-stream-pipeline [model on-event]
  "Build a fresh (state parser parser-error) tuple for one streaming POST.
   The parser feeds decoded SSE frames into process-stream-chunk! and
   captures JSON-decode failures into parser-error.message."
  (let [state (new-stream-state model)
        parser-error {:message nil}
        parser (sse.new-parser
                 (fn [ev]
                   (when (and (not parser-error.message)
                              (not= ev.data "[DONE]")
                              (not= ev.data ""))
                     (let [(ok? decoded) (pcall json.decode ev.data)]
                       (if ok?
                           (process-stream-chunk! state decoded on-event)
                           (set parser-error.message decoded))))))]
    (values state parser parser-error)))

(fn finalize-stream [state parser parser-error model resp on-event]
  "Shared post-request handling for the streaming pipeline."
  (when (not resp.error) (parser.finish))
  (if resp.error
      (let [asst (types.assistant-error API PROVIDER model resp.error)]
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (not= parser-error.message nil)
      (let [asst (types.assistant-error API PROVIDER model parser-error.message)]
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (or (< resp.status 200) (>= resp.status 300))
      (let [asst (types.assistant-error API PROVIDER model
                                        (.. "HTTP " resp.status ": " resp.body))]
        (log.error (.. "http " resp.status ": " resp.body))
        (when on-event (on-event {:type :error :message asst}))
        asst)
      ;; 2xx that closed without a finish_reason: incomplete, not a silent
      ;; empty :stop turn (see new-stream-state :saw-terminal?).
      (not state.saw-terminal?)
      (let [asst (types.assistant-error API PROVIDER model
                                        "stream ended without a completion event")]
        (log.error "openai-completions: stream ended without a completion event")
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (finalize-stream-state state on-event)))

;; @doc fen.extensions.provider_openai.openai_completions.complete
;; kind: function
;; signature: (complete model context options ?on-event ?yield-fn) -> AssistantMessage
;; summary: Execute one Chat Completions provider call, choosing streaming/non-streaming and cooperative/blocking transport from callbacks.
;; tags: provider openai completions complete
(fn complete [model context options ?on-event ?yield-fn]
  "Single entry. Routes by ?on-event / ?yield-fn:
     - `?on-event` set → native streaming pipeline (SSE), driving the
       transport cooperatively when ?yield-fn is given, blocking otherwise.
     - `?on-event` nil → non-streaming POST. Cooperative when ?yield-fn is
       given, blocking otherwise.
   Returns a canonical AssistantMessage in every case; on transport or
   HTTP failure the message has stop-reason :error with error-message set."
  (if ?on-event
      (let [latest {:state nil :parser nil :parser-error nil}]
        (?on-event {:type :start})
        (let [resp (retry.with-retry
                     (retry.options PROVIDER options ?on-event)
                     (fn [_attempt]
                       (let [(state parser parser-error) (make-stream-pipeline model ?on-event)
                             req-opts (build-request-opts model context options
                                                          (fn [chunk] (parser.feed chunk)))]
                         (set latest.state state)
                         (set latest.parser parser)
                         (set latest.parser-error parser-error)
                         (set req-opts.yield ?yield-fn)
                         (http.request req-opts)))
                     ?yield-fn)]
          (finalize-stream latest.state latest.parser latest.parser-error model resp ?on-event)))
      (let [resp (retry.with-retry
                   (retry.options PROVIDER options ?on-event)
                   (fn [_attempt]
                     (let [req-opts (build-request-opts model context options nil)]
                       (set req-opts.yield ?yield-fn)
                       (http.request req-opts)))
                   ?yield-fn)]
        (response->assistant model resp))))

;; @doc fen.extensions.provider_openai.openai_completions.api
;; kind: data
;; signature: keyword
;; summary: Provider API family keyword used by registry metadata for the Chat Completions adapter.
;; tags: provider openai completions metadata
;; @doc fen.extensions.provider_openai.openai_completions.provider
;; kind: data
;; signature: keyword
;; summary: Provider owner keyword used on canonical assistant messages emitted by the Chat Completions adapter.
;; tags: provider openai completions metadata
;; @doc fen.extensions.provider_openai.openai_completions.default-base-url
;; kind: data
;; signature: string
;; summary: Default OpenAI v1 API root used when models.json or provider options do not override the base URL.
;; tags: provider openai completions metadata
{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : convert-messages
 : convert-tools
 : map-stop-reason
 : parse-response
 : process-stream-chunk!
 : new-stream-state
 : finalize-stream-state
 : finalize-stream
 : build-body
 : complete}
