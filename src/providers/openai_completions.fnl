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

(local types (require :core.types))
(local json (require :util.json))
(local log (require :util.log))
(local http (require :util.http))
(local sse (require :util.sse))

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

(fn convert-messages [messages system-prompt compat]
  "Canonical Messages + optional system prompt → OpenAI ChatCompletionMessageParam[]."
  (let [out []
        echo-reasoning? (or (?. compat :echoReasoningFields)
                            (?. compat :thinkingFormat))]
    (when (and system-prompt (not= system-prompt ""))
      (table.insert out {:role :system :content system-prompt}))
    (each [_ m (ipairs (or messages []))]
      (table.insert out (convert-message m echo-reasoning?)))
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
    (when (and context.tools (> (length context.tools) 0))
      (set body.tools (convert-tools context.tools))
      (set body.tool_choice :auto)
      (set body.parallel_tool_calls (parallel-tool-calls? options)))
    body))

(fn request-headers [api-key extra]
  (let [headers (or extra ["Content-Type: application/json"])]
    ;; Skip the Authorization header entirely when there's no key.
    ;; Ollama and other auth-less local servers ignore Bearer tokens but
    ;; sending an empty `Authorization: Bearer ` is at best noise and at
    ;; worst makes some servers reject the request.
    (when (and api-key (not= api-key ""))
      (table.insert headers 1 (.. "Authorization: Bearer " api-key)))
    headers))

(fn configure-easy! [easy url body headers opts write-fn]
  (easy:setopt_url url)
  (easy:setopt_post 1)
  (easy:setopt_postfields (json.encode body))
  (easy:setopt_httpheader headers)
  (easy:setopt_timeout_ms (or opts.timeout-ms DEFAULT-TIMEOUT-MS))
  (easy:setopt_connecttimeout_ms
    (or opts.connect-timeout-ms DEFAULT-CONNECT-TIMEOUT-MS))
  (easy:setopt_writefunction write-fn))

(fn make-request [model context options]
  (let [opts (or options {})
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (build-url base-url)
        max-tokens (or opts.max-tokens 16384)
        compat opts.compat
        body (build-body model context max-tokens compat opts)
        curl (require :cURL)
        chunks []
        easy (curl.easy)
        headers (request-headers api-key ["Content-Type: application/json"])]
    (configure-easy! easy url body headers opts
                     (fn [chunk] (table.insert chunks chunk) (length chunk)))
    (values easy chunks)))

(fn response->assistant [model chunks status ok? err]
  (if (not ok?)
      (do (log.error (.. "curl perform failed: " (tostring err)))
          (types.assistant-error API PROVIDER model err))
      (let [raw (table.concat chunks)
            (decoded? value) (pcall json.decode raw)]
        (if (not decoded?)
            (do (log.error (.. "json decode failed: " (tostring value) " body=" raw))
                (types.assistant-error API PROVIDER model value))
            (if (or (< status 200) (>= status 300))
                (do (log.error (.. "http " status ": " raw))
                    (types.assistant-error API PROVIDER model
                      (.. "HTTP " status ": " raw)))
                (parse-response value model))))))

(fn new-stream-state [model]
  {:model model
   :content []
   :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
   :stop-reason :stop
   :error-message nil
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

(fn process-stream-chunk! [state chunk emit]
  "Consume one decoded OpenAI ChatCompletionChunk-like table."
  (update-stream-usage! state chunk.usage)
  (let [choice (?. chunk :choices 1)]
    (when choice
      (when (?. choice :usage)
        (update-stream-usage! state choice.usage))
      (when choice.finish_reason
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

(fn make-stream-request [model context options on-event]
  (let [opts (or options {})
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (build-url base-url)
        max-tokens (or opts.max-tokens 16384)
        compat opts.compat
        body (build-body model context max-tokens compat opts)
        curl (require :cURL)
        chunks []
        state (new-stream-state model)
        parser-error {:message nil}
        parser (sse.new-parser
                 (fn [ev]
                   (when (and (not parser-error.message)
                              (not= ev.data "[DONE]")
                              (not= ev.data ""))
                     (let [(ok? decoded) (pcall json.decode ev.data)]
                       (if ok?
                           (process-stream-chunk! state decoded on-event)
                           (set parser-error.message decoded))))))
        easy (curl.easy)
        headers (request-headers api-key ["Accept: text/event-stream"
                                          "Content-Type: application/json"])]
    (set body.stream true)
    (when (= (?. compat :supportsUsageInStreaming) true)
      (set body.stream_options {:include_usage true}))
    (configure-easy! easy url body headers opts
                     (fn [chunk]
                       (table.insert chunks chunk)
                       (parser.feed chunk)
                       (length chunk)))
    (values easy chunks state parser parser-error)))

(fn complete [model context options]
  "Non-streaming POST. Returns a canonical AssistantMessage; on transport or
   HTTP failure the message has stop-reason :error with error-message set."
  (let [(easy chunks) (make-request model context options)
        (ok? err) (pcall #(easy:perform))
        status (easy:getinfo_response_code)]
    (easy:close)
    (response->assistant model chunks status ok? err)))

(fn complete-coop [model context options yield-fn]
  "Cooperative non-streaming POST for interactive mode. Drives the easy handle
   through curl multi one short step per coroutine resume and calls `yield-fn`
   between steps so the TUI can keep processing input/redraws while the
   provider request is in flight."
  (let [(easy chunks) (make-request model context options)
        (ok? err) (http.perform-coop easy yield-fn)
        status (easy:getinfo_response_code)]
    (easy:close)
    (response->assistant model chunks status ok? err)))

(fn complete-stream [model context options on-event yield-fn]
  "Native streaming Chat Completions path. Emits provider stream events while
   reducing chunks into the same canonical AssistantMessage shape returned by
   parse-response."
  (let [(easy chunks state parser parser-error) (make-stream-request model context options on-event)]
    (when on-event (on-event {:type :start}))
    (let [(ok? err) (http.perform-coop easy yield-fn)
          status (easy:getinfo_response_code)]
    (easy:close)
    (when ok?
      (parser.finish))
    (if (not ok?)
        (let [asst (types.assistant-error API PROVIDER model err)]
          (when on-event (on-event {:type :error :message asst}))
          asst)
        (not= parser-error.message nil)
        (let [asst (types.assistant-error API PROVIDER model parser-error.message)]
          (when on-event (on-event {:type :error :message asst}))
          asst)
        (or (< status 200) (>= status 300))
        (let [raw (table.concat chunks)
              asst (types.assistant-error API PROVIDER model (.. "HTTP " status ": " raw))]
          (log.error (.. "http " status ": " raw))
          (when on-event (on-event {:type :error :message asst}))
          asst)
        (finalize-stream-state state on-event)))))

{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : convert-messages
 : convert-tools
 : map-stop-reason
 : parse-response
 : process-stream-chunk!
 : finalize-stream-state
 : build-body
 : complete
 : complete-coop
 : complete-stream}
