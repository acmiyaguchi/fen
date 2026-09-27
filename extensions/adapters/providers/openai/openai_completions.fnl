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
(local stream-chunks (require :fen.util.stream_chunks))
(local streaming (require :fen.extensions.provider_shared.streaming))
(local model-catalog (require :fen.extensions.provider_openai.openai_model_catalog))

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

;; A flavor lets another OpenAI-compatible adapter (e.g. OpenRouter) reuse this
;; module's wire conversion and stream reducer while owning its identity and
;; request policy:
;;   :api :provider :default-base-url  canonical identity + endpoint root
;;   :reasoning-details?               capture `reasoning_details` into a
;;                                     thinking block and echo it back
;;   :patch-headers (fn [headers opts streaming?]) -> headers
;;   :patch-body    (fn [body model context opts streaming?]) -> body
(local OPENAI-FLAVOR {:api API :provider PROVIDER :default-base-url DEFAULT-BASE-URL})

(fn ends-with? [s suffix]
  (let [n (length suffix)]
    (and (>= (length s) n)
         (= (string.sub s (- (length s) n -1)) suffix))))

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

(fn reasoning-details-of [block]
  "Decode the `reasoning_details` array stored on a thinking block, or nil.
   Captured details are JSON-encoded into :thinking-signature (an array, so it
   never collides with reasoning field names or Responses item objects)."
  (let [sig (and (= block.type :thinking) block.thinking-signature)]
    (when (and (= (type sig) :string) (= (string.sub sig 1 1) "["))
      (let [(ok? details) (pcall json.decode sig)]
        (when (and ok? (= (type details) :table)) details)))))

(fn reasoning-details-for-echo [content]
  "Concatenate every captured reasoning_details array on an assistant message,
   unchanged and in order, or nil when there is none."
  (let [out []]
    (each [_ block (ipairs (or content []))]
      (each [_ detail (ipairs (or (reasoning-details-of block) []))]
        (table.insert out detail)))
    (when (> (length out) 0) out)))

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

(fn convert-message [m echo-reasoning? echo-details?]
  (if (= m.role :user)
      {:role :user :content (text-of-content m.content)}

      (= m.role :assistant)
      (let [text (text-of-content m.content)
            tool-calls (extract-tool-calls m.content)
            (reasoning-field reasoning-text) (reasoning-content-for-echo m.content)
            details (when echo-details? (reasoning-details-for-echo m.content))
            out {:role :assistant}]
        ;; OpenAI requires content OR tool_calls. Null content is only valid
        ;; when tool_calls is present; otherwise send empty string.
        (set out.content
             (if (and (= text "") (> (length tool-calls) 0)) json.null text))
        (when (and echo-reasoning? reasoning-field)
          (tset out reasoning-field reasoning-text))
        (when details
          (set out.reasoning_details details))
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

(fn convert-messages [messages system-prompt compat ?flavor]
  "Canonical Messages + optional system prompt → OpenAI ChatCompletionMessageParam[].
   If a replayed transcript contains an orphaned assistant tool call from an
   older interrupted run, synthesize a tool error message instead of sending
   invalid history that the provider rejects. A flavor with
   `:reasoning-details?` echoes captured `reasoning_details` unchanged."
  (let [out []
        pending []
        echo-reasoning? (or (?. compat :echoReasoningFields)
                            (?. compat :thinkingFormat))
        echo-details? (?. ?flavor :reasoning-details?)]
    (when (and system-prompt (not= system-prompt ""))
      (table.insert out {:role :system :content system-prompt}))
    (each [_ m (ipairs (or messages []))]
      (when (and (> (length pending) 0) (not= m.role :tool-result))
        (flush-pending! out pending))
      (table.insert out (convert-message m echo-reasoning? echo-details?))
      (if (= m.role :assistant)
          (remember-tool-calls! pending m)
          (= m.role :tool-result)
          (remove-pending! pending m.tool-call-id)))
    (flush-pending! out pending)
    out))

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

(fn present-table [v]
  "v when it is a real table; nil for nil and the decoded JSON null sentinel,
   which is truthy and raises when indexed. #482"
  (when (and (= (type v) :table) (not (json.null? v))) v))

(fn number-or-zero [v]
  (if (= (type v) :number) v 0))

(fn usage->canonical [usage]
  "OpenAI-compatible usage → canonical usage. `cached_tokens` is a cache read;
   `cache_write_tokens` (OpenRouter and other gateways) is a cache write. Both
   are included in prompt_tokens, so uncached input subtracts them."
  (let [usage (or (present-table usage) {})
        details (or (present-table usage.prompt_tokens_details) {})
        cached (number-or-zero details.cached_tokens)
        written (number-or-zero details.cache_write_tokens)
        raw-input (number-or-zero usage.prompt_tokens)]
    {:input (math.max (- raw-input cached written) 0)
     :output (number-or-zero usage.completion_tokens)
     :cache-read cached
     :cache-write written
     :total-tokens (number-or-zero usage.total_tokens)}))

(fn provider-error-message [err]
  "Human-readable text for an OpenAI-compatible `{error: {message, code}}`
   payload, such as an OpenRouter mid-stream error chunk."
  (let [err (present-table err)
        msg (?. err :message)
        code (?. err :code)
        text (if (and (= (type msg) :string) (not= msg "")) msg "unknown error")]
    (if (or (= (type code) :string) (= (type code) :number))
        (.. "Provider error (" (tostring code) "): " text)
        (.. "Provider error: " text))))

(fn merge-reasoning-detail! [acc detail]
  "Fold one streamed reasoning_details item into acc. Consecutive items with the
   same `type` and `index` are fragments of one detail: string payloads
   (`text`, `summary`, `data`) concatenate and other fields take the latest
   non-null value. Anything else starts a new detail."
  (when (present-table detail)
    (let [last (. acc (length acc))
          index detail.index]
      (if (and last (= last.type detail.type)
               (= (type index) :number) (= last.index index))
          (each [k v (pairs detail)]
            (if (and (or (= k :text) (= k :summary) (= k :data))
                     (= (type v) :string))
                (tset last k (.. (if (= (type (. last k)) :string) (. last k) "") v))
                (json.null? v)
                (when (= (. last k) nil) (tset last k v))
                (tset last k v)))
          (table.insert acc detail)))))

(fn attach-reasoning-details! [content details]
  "Store a non-empty reasoning_details array on the first thinking block,
   adding an empty one when the provider sent only opaque details (for example
   Gemini thought signatures on a tool-call turn)."
  (when (and details (> (length details) 0))
    (var block nil)
    (each [_ b (ipairs content) &until block]
      (when (= b.type :thinking) (set block b)))
    (when (not block)
      (set block (types.thinking-block {:thinking ""}))
      (table.insert content block))
    (set block.thinking-signature (json.encode details))))

(fn parse-response [resp model ?flavor]
  "OpenAI response → canonical AssistantMessage."
  (let [flavor (or ?flavor OPENAI-FLAVOR)
        choice (?. resp :choices 1)
        msg (?. choice :message)
        finish (?. choice :finish_reason)
        (stop-reason error-message) (if (present-table resp.error)
                                        (values :error (provider-error-message resp.error))
                                        (map-stop-reason finish))
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
    ;; OpenAI-compatible servers (Ollama/vLLM/proxies) emit `tool_calls: null`
    ;; on plain text turns; `ipairs` over the sentinel would raise on a 200
    ;; response. #482
    (when (and msg msg.tool_calls (not (json.null? msg.tool_calls)))
      (each [_ tc (ipairs msg.tool_calls)]
        (table.insert content
                      (types.tool-call-block
                        tc.id
                        (?. tc :function :name)
                        (decode-tool-arguments (?. tc :function :arguments))))))
    (when (and flavor.reasoning-details? msg (present-table msg.reasoning_details))
      (attach-reasoning-details! content msg.reasoning_details))
    (types.assistant-message
      {:api flavor.api :provider flavor.provider : model
       : content
       :usage (usage->canonical resp.usage)
       : stop-reason
       : error-message})))

;; ----------------------------------------------------------------
;; HTTP transport
;; ----------------------------------------------------------------

(fn compat-thinking-enabled? [compat]
  (let [explicit (?. compat :enableThinking)]
    (if (not= explicit nil) explicit true)))

(local THINKING-FORMATS "zai, qwen, qwen-chat-template, deepseek")
;; Unknown formats already warned about, so a stale models.json warns once
;; per process (and again after /reload) instead of on every request.
(local warned-thinking-formats {})

(fn warn-unknown-thinking-format! [fmt base-url]
  (let [key (tostring fmt)]
    (when (not (. warned-thinking-formats key))
      (tset warned-thinking-formats key true)
      (log.warn (.. "openai-completions: ignoring unknown compat.thinkingFormat \""
                    key "\" for provider at " (tostring (or base-url DEFAULT-BASE-URL))
                    " (known: " THINKING-FORMATS ")"
                    (if (= key :openrouter)
                        "; for OpenRouter use the `openrouter` provider or \"api\": \"openrouter-completions\""
                        ""))))))

(fn apply-thinking-compat [body compat ?base-url]
  "Enable common OpenAI-compatible thinking knobs when models.json sets
   compat.thinkingFormat. Default to enabled because selecting a format is an
   explicit provider opt-in; compat.enableThinking=false disables it. An
   unknown format is ignored with a one-time warning."
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
            (warn-unknown-thinking-format! fmt ?base-url)))))
  body)

(fn parallel-tool-calls? [options]
  "Provider option normalized across providers. Defaults on; only explicit
   `:parallel-tool-calls false` disables it."
  (let [v (?. options :parallel-tool-calls)]
    (if (= v nil) true v)))

(fn build-body [model context max-tokens compat options ?flavor]
  "Build the chat-completions request body. `compat` is an optional table of
   per-provider OpenAI-compat overrides (see `core.llm.models`). Supports
   `:maxTokensField` and a small `:thinkingFormat` set for OpenAI-compatible
   reasoning providers. `options.parallel-tool-calls` controls OpenAI's
   explicit `parallel_tool_calls` request flag; `options.tool-choice :none`
   sends `tool_choice: \"none\"` while keeping the tool definitions."
  (let [max-field (or (?. compat :maxTokensField) :max_completion_tokens)
        body {: model
              :messages (convert-messages context.messages context.system-prompt
                                          compat ?flavor)}]
    (tset body max-field (or max-tokens 16384))
    (apply-thinking-compat body compat (?. options :base-url))
    (when (and options options.reasoning-effort)
      (set body.reasoning_effort options.reasoning-effort))
    (when (and context.tools (> (length context.tools) 0))
      (set body.tools (convert-tools context.tools))
      (set body.tool_choice (if (= (?. options :tool-choice) :none) :none :auto))
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

(fn build-request-opts [model context options ?on-chunk ?flavor]
  "Assemble a fen.util.http opts table for a Chat Completions POST. When
   ?on-chunk is provided, the request is configured for streaming
   (`stream:true`, `Accept: text/event-stream`). A flavor's :patch-headers
   and :patch-body get the last word on the outgoing request."
  (let [flavor (or ?flavor OPENAI-FLAVOR)]
    (streaming.build-request-opts
      {:url (fn [opts _streaming?]
              (build-url (or opts.base-url flavor.default-base-url)))
       :headers (fn [opts streaming?]
                  (let [headers (request-headers opts.api-key streaming?)]
                    (if flavor.patch-headers
                        (flavor.patch-headers headers opts streaming?)
                        headers)))
       :build-body (fn [model context opts streaming?]
                     (let [compat opts.compat
                           body (build-body model context (or opts.max-tokens 16384)
                                            compat opts flavor)]
                       (when streaming?
                         (set body.stream true)
                         (when (= (?. compat :supportsUsageInStreaming) true)
                           (set body.stream_options {:include_usage true})))
                       (if flavor.patch-body
                           (flavor.patch-body body model context opts streaming?)
                           body)))
       :default-timeout-ms DEFAULT-TIMEOUT-MS
       :default-connect-timeout-ms DEFAULT-CONNECT-TIMEOUT-MS}
      model context options ?on-chunk)))

(fn response->assistant [model resp ?flavor]
  (let [flavor (or ?flavor OPENAI-FLAVOR)
        api flavor.api
        provider flavor.provider]
    (if resp.error
        (do (log.error (.. "http transport failed: " resp.error))
            (types.assistant-error api provider model resp.error))
        (let [raw resp.body
              (decoded? value) (pcall json.decode raw)]
          (if (not decoded?)
              (do (log.error (.. "json decode failed: " (tostring value) " body=" raw))
                  (types.assistant-error api provider model value))
              (if (or (< resp.status 200) (>= resp.status 300))
                  (do (log.error (.. "http " resp.status ": " raw))
                      (types.assistant-error api provider model
                        (.. "HTTP " resp.status ": " raw)))
                  (parse-response value model flavor)))))))

(fn new-stream-state [model ?flavor]
  {:model model
   :flavor (or ?flavor OPENAI-FLAVOR)
   ;; Streamed reasoning_details fragments, folded by merge-reasoning-detail!.
   :reasoning-details []
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
            (let [text (stream-chunks.materialize! block :text :text-chunks)]
              (when emit (emit {:type :text-end :content-index idx :content text})))
            (= block.type :thinking)
            (let [thinking (stream-chunks.materialize! block :thinking :thinking-chunks)]
              (when emit (emit {:type :thinking-end :content-index idx :content thinking})))
            (= block.type :tool-call)
            (do
              (let [args (stream-chunks.materialize! block :partial-args :partial-args-chunks)]
                (set block.arguments (decode-tool-arguments (if (= args "") "{}" args))))
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
  ;; With `stream_options.include_usage`, every delta chunk before the final one
  ;; carries `usage: null` (the truthy cjson.null sentinel). A bare `(when usage)`
  ;; would pass and then crash indexing the sentinel, so skip decoded nulls. #482
  (when (present-table usage)
    (set state.usage (usage->canonical usage))))

(fn process-stream-chunk! [state chunk emit]
  "Consume one decoded OpenAI ChatCompletionChunk-like table."
  (update-stream-usage! state chunk.usage)
  (let [choice (?. chunk :choices 1)]
    (when choice
      (when (?. choice :usage)
        (update-stream-usage! state choice.usage))
      ;; Delta frames carry `finish_reason: null` (the truthy cjson.null
      ;; sentinel) until the genuine terminal chunk. A bare `(when
      ;; choice.finish_reason)` fires on every delta, flipping saw-terminal? and
      ;; forcing stop-reason :error from frame one — so a truncated stream would
      ;; read as cleanly terminated. Treat an explicit null as absent. #482
      (when (and choice.finish_reason (not (json.null? choice.finish_reason)))
        (set state.saw-terminal? true)
        (let [(stop err) (map-stop-reason choice.finish_reason)]
          (set state.stop-reason stop)
          (set state.error-message err)))
      (let [delta choice.delta]
        ;; Some OpenAI-compatible servers emit `delta: null` (the truthy
        ;; cjson.null sentinel) on housekeeping frames; a bare `(when delta)`
        ;; passes and the indexing below would raise. Treat null as absent. #482
        (when (and delta (not (json.null? delta)))
          (when (and (= (type delta.content) :string) (not= delta.content ""))
            (let [block (ensure-text-block! state emit)]
              (stream-chunks.append! block :text :text-chunks delta.content)
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
              (stream-chunks.append! block :thinking :thinking-chunks reasoning-value)
              (when emit
                (emit {:type :thinking-delta
                       :content-index (current-content-index state)
                       :delta reasoning-value}))))
          ;; OpenAI-compatible servers can emit `tool_calls: null` (the
          ;; cjson.null sentinel) on plain-text deltas; `ipairs` over the
          ;; sentinel would raise. Mirrors the non-streaming guard. #482
          (when (and delta.tool_calls (not (json.null? delta.tool_calls)))
            (each [_ tc (ipairs delta.tool_calls)]
              (let [block (ensure-tool-block! state tc emit)
                    arg-delta (or (?. tc :function :arguments) "")]
                (when (and (?. tc :function :name) (= block.name ""))
                  (set block.name tc.function.name))
                (when (and tc.id (= block.id ""))
                  (set block.id tc.id))
                (when (not= arg-delta "")
                  (stream-chunks.append! block :partial-args :partial-args-chunks arg-delta)
                  (when emit
                    (emit {:type :tool-call-delta
                           :content-index (current-content-index state)
                           :delta arg-delta}))))))
          (when (and (?. state :flavor :reasoning-details?)
                     (present-table delta.reasoning_details))
            (each [_ detail (ipairs delta.reasoning_details)]
              (merge-reasoning-detail! state.reasoning-details detail)))))))
  ;; Gateways such as OpenRouter report a failure after the 200 is committed
  ;; as a chunk carrying `error` (usually with `finish_reason: "error"`). It is
  ;; terminal, and its message beats the bare finish_reason text.
  (when (present-table chunk.error)
    (set state.saw-terminal? true)
    (set state.stop-reason :error)
    (set state.error-message (provider-error-message chunk.error)))
  state)

;; @doc fen.extensions.provider_openai.openai_completions.finalize-stream-state
;; kind: function
;; signature: (finalize-stream-state state emit) -> AssistantMessage
;; summary: Close the streaming content block state, infer tool-use stops, emit the terminal event, and return the canonical assistant message.
;; tags: provider openai completions streaming
(fn finalize-stream-state [state emit]
  (let [flavor (or state.flavor OPENAI-FLAVOR)]
    (streaming.finalize-stream-state
      {:api flavor.api :provider flavor.provider :state state :emit emit
       :finish (fn [state emit]
                 (finish-current-block! state emit)
                 (attach-reasoning-details! state.content state.reasoning-details))})))

(fn make-stream-pipeline [model on-event ?flavor]
  "Build a fresh (state parser parser-error) tuple for one streaming POST.
   The parser feeds decoded SSE frames into process-stream-chunk! and
   captures JSON-decode failures into parser-error.message."
  (streaming.make-stream-pipeline
    {:model model
     :on-event on-event
     :new-state (fn [model] (new-stream-state model ?flavor))
     :process-event process-stream-chunk!
     ;; Many OpenAI-compatible endpoints close the stream with only a [DONE]
     ;; sentinel and no finish_reason. Treat it as terminal so finalize-stream
     ;; does not report a false incomplete stream; any prior stop-reason from a
     ;; finish_reason is preserved.
     :done-sentinel "[DONE]"}))

(fn finalize-stream [state parser parser-error model resp on-event]
  "Shared post-request handling for the streaming pipeline."
  (let [flavor (or (?. state :flavor) OPENAI-FLAVOR)]
    (streaming.finalize-stream
      {:api flavor.api
       :provider flavor.provider
       :model model
       :state state
       :parser parser
       :parser-error parser-error
       :resp resp
       :on-event on-event
       :finalize-state finalize-stream-state
       :incomplete-log-prefix (tostring flavor.api)})))

(fn complete-with [flavor model context options ?on-event ?yield-fn]
  "`complete` for an OpenAI-compatible flavor (see OPENAI-FLAVOR). Adapters
   that speak Chat Completions with their own identity and request policy
   call this instead of forking the wire conversion or stream reducer."
  (streaming.complete
    {:provider flavor.provider
     :model model
     :context context
     :options options
     :on-event ?on-event
     :yield-fn ?yield-fn
     :build-request-opts (fn [model context options ?on-chunk]
                           (build-request-opts model context options ?on-chunk flavor))
     :make-stream-pipeline (fn [model on-event]
                             (make-stream-pipeline model on-event flavor))
     :finalize-stream finalize-stream
     :response->assistant (fn [model resp]
                            (response->assistant model resp flavor))}))

(fn complete [model context options ?on-event ?yield-fn]
  "Single entry. Routes by ?on-event / ?yield-fn:
     - `?on-event` set → native streaming pipeline (SSE), driving the
       transport cooperatively when ?yield-fn is given, blocking otherwise.
     - `?on-event` nil → non-streaming POST. Cooperative when ?yield-fn is
       given, blocking otherwise.
   Returns a canonical AssistantMessage in every case; on transport or
   HTTP failure the message has stop-reason :error with error-message set."
  (complete-with OPENAI-FLAVOR model context options ?on-event ?yield-fn))

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
 : build-request-opts
 :list-models model-catalog.list-models
 : complete-with
 : complete}
