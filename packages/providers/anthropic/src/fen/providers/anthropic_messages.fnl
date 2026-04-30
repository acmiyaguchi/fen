;; Anthropic Messages provider.
;;
;; Mirrors pi-mono's `packages/ai/src/providers/anthropic.ts` surface:
;; convert-messages, convert-tools, map-stop-reason, parse-response, complete.
;;
;; Wire shape highlights vs OpenAI Chat Completions:
;;   - System prompt is a top-level field, NOT a {role:system} message.
;;   - Tools are flat {name, description, input_schema}, no `function:` wrap.
;;   - Assistant content is always an array of typed blocks
;;     (text/thinking/tool_use). No separate `tool_calls` field.
;;   - Tool results live INSIDE a {role:user} message as
;;     {type:"tool_result", tool_use_id, content, is_error?} blocks.
;;     Consecutive tool results are batched into one user message.
;;   - Auth header is `x-api-key`, plus `anthropic-version: 2023-06-01`.
;;
;; Extended thinking: pass `:thinking-budget N` in options to enable Claude's
;; reasoning blocks. Returned blocks are surfaced as canonical
;; ThinkingContent and must be echoed back on the next turn (with their
;; opaque `signature`) — convert-messages preserves them.

(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local http (require :fen.util.http))
(local sse (require :fen.util.sse))

(local API :anthropic-messages)
(local PROVIDER :anthropic)
(local DEFAULT-BASE-URL "https://api.anthropic.com/v1/messages")
(local DEFAULT-VERSION "2023-06-01")
;; Bound how long the request can hang. Anthropic's extended-thinking
;; responses are minutes-long; the overall cap is generous, and the
;; connect cap fails fast on bad endpoints. Override per-call via
;; options :timeout-ms / :connect-timeout-ms.
(local DEFAULT-TIMEOUT-MS 600000)
(local DEFAULT-CONNECT-TIMEOUT-MS 30000)

;; Prompt cache marker. Anthropic engages prefix caching only when
;; cache_control is set on a block; the same prefix on later turns then
;; counts as a read against the cached entry. We mark three cut points
;; (system / last tool / last message) — mirrors pi-mono's anthropic.ts.
;; The 1h tier matches pi-mono; fall back to the default 5m if Anthropic
;; ever retires it.
(local CACHE-CONTROL-1H {:type :ephemeral :ttl :1h})

;; ----------------------------------------------------------------
;; Outbound: canonical → Anthropic wire
;; ----------------------------------------------------------------

(fn block-to-wire [block]
  (if (= block.type :text)
      {:type :text :text (or block.text "")}
      (= block.type :thinking)
      (let [out {:type :thinking :thinking (or block.thinking "")}]
        ;; Anthropic's field is `signature`; canonical is `thinking-signature`.
        (when block.thinking-signature
          (set out.signature block.thinking-signature))
        out)
      (= block.type :tool-call)
      {:type :tool_use
       :id block.id
       :name block.name
       :input (or block.arguments {})}
      (error (.. "anthropic_messages: unhandled block type: "
                 (tostring block.type)))))

(fn assistant-content-to-wire [content]
  (let [out []]
    (each [_ b (ipairs (or content []))]
      (table.insert out (block-to-wire b)))
    out))

(fn user-content-to-wire [content]
  ;; Canonical UserMessage.content is string OR [TextContent]. Anthropic
  ;; accepts either; pass strings through and convert block arrays.
  (if (= (type content) :string)
      content
      (let [out []]
        (each [_ b (ipairs (or content []))]
          (when (= b.type :text)
            (table.insert out {:type :text :text (or b.text "")})))
        out)))

(fn tool-result-block [m]
  ;; Canonical ToolResultMessage → Anthropic tool_result block.
  (let [block {:type :tool_result
               :tool_use_id m.tool-call-id
               :content (let [parts []]
                          (each [_ b (ipairs (or m.content []))]
                            (when (= b.type :text)
                              (table.insert parts
                                            {:type :text :text (or b.text "")})))
                          parts)}]
    (when m.is-error? (set block.is_error true))
    block))

(fn convert-messages [messages _system-prompt]
  "Canonical Messages → Anthropic MessageParam[]. The system prompt is NOT
   included; it goes in the top-level `system` field. Consecutive
   tool-result messages are batched into one user message, since Anthropic
   requires that grouping."
  (let [out []
        n (length (or messages []))]
    (var i 1)
    (while (<= i n)
      (let [m (. messages i)]
        (if (= m.role :user)
            (do (table.insert out
                              {:role :user
                               :content (user-content-to-wire m.content)})
                (set i (+ i 1)))
            (= m.role :assistant)
            (do (table.insert out
                              {:role :assistant
                               :content (assistant-content-to-wire m.content)})
                (set i (+ i 1)))
            (= m.role :tool-result)
            ;; Batch this and any directly-following tool-result messages.
            (let [blocks []]
              (var j i)
              (while (and (<= j n) (= (. messages j :role) :tool-result))
                (table.insert blocks (tool-result-block (. messages j)))
                (set j (+ j 1)))
              (table.insert out {:role :user :content blocks})
              (set i j))
            (error (.. "anthropic_messages: unhandled message role: "
                       (tostring m.role))))))
    out))

(fn convert-tools [tools]
  "Canonical Tool[] → Anthropic Tool[] (flat, with input_schema)."
  (let [out []]
    (each [_ t (ipairs (or tools []))]
      (table.insert out
                    {:name t.name
                     :description t.description
                     :input_schema t.parameters}))
    out))

;; ----------------------------------------------------------------
;; Inbound: Anthropic wire → canonical
;; ----------------------------------------------------------------

(fn map-stop-reason [reason]
  "Anthropic stop_reason → canonical StopReason. Mirrors pi-mono
   anthropic.ts:1146-1166."
  (case reason
    :end_turn (values :stop nil)
    :max_tokens (values :length nil)
    :tool_use (values :tool-use nil)
    :refusal (values :error "Provider stop_reason: refusal")
    ;; Stop is good enough; caller can resubmit if they want.
    :pause_turn (values :stop nil)
    :stop_sequence (values :stop nil)
    :sensitive (values :error "Provider stop_reason: sensitive")
    ;; default — preserve the raw value rather than throwing.
    _ (values :error (.. "Provider stop_reason: " (tostring reason)))))

(fn parse-response [resp model]
  "Anthropic response → canonical AssistantMessage."
  (let [(stop-reason error-message) (map-stop-reason resp.stop_reason)
        usage (or resp.usage {})
        content []]
    (each [_ b (ipairs (or resp.content []))]
      (case b.type
        :text
        (table.insert content (types.text-block (or b.text "")))

        :thinking
        (table.insert content
                      (types.thinking-block
                        {:thinking (or b.thinking "")
                         :thinking-signature b.signature
                         :redacted false}))

        :tool_use
        (table.insert content
                      (types.tool-call-block b.id b.name (or b.input {})))

        ;; Unknown block type — skip with a log.
        _
        (log.warn (.. "anthropic_messages: unknown content block type: "
                      (tostring b.type)))))
    (types.assistant-message
      {:api API :provider PROVIDER : model
       : content
       :usage {:input (or usage.input_tokens 0)
               :output (or usage.output_tokens 0)
               :cache-read (or usage.cache_read_input_tokens 0)
               :cache-write (or usage.cache_creation_input_tokens 0)
               :total-tokens (+ (or usage.input_tokens 0)
                                (or usage.output_tokens 0))}
       : stop-reason
       : error-message})))

;; ----------------------------------------------------------------
;; HTTP transport
;; ----------------------------------------------------------------

(fn mark-last-message-cache! [messages]
  "Set cache_control on the last content block of the last message, in
   place. If the last message's content is a string, convert it to a
   single-block array first. No-ops on an empty list."
  (let [n (length messages)]
    (when (> n 0)
      (let [last (. messages n)]
        (if (= (type last.content) :string)
            (set last.content [{:type :text :text last.content
                                :cache_control CACHE-CONTROL-1H}])
            (let [blocks last.content
                  bn (length blocks)]
              (when (> bn 0)
                (set (. blocks bn :cache_control) CACHE-CONTROL-1H))))))))

(fn parallel-tool-calls? [options]
  "Provider option normalized across providers. Defaults on; only explicit
   `:parallel-tool-calls false` disables it."
  (let [v (?. options :parallel-tool-calls)]
    (if (= v nil) true v)))

(fn build-body [model context max-tokens options]
  (let [;; Prompt-cache markers: opt out via options.no-cache? for tests
        ;; or pathological one-shot requests where caching would hurt.
        cache? (not (and options options.no-cache?))
        wire-messages (convert-messages context.messages context.system-prompt)
        body {: model
              :max_tokens (or max-tokens 16384)
              :messages wire-messages}]
    (when (and context.system-prompt (not= context.system-prompt ""))
      (if cache?
          ;; Convert string system → array form so we can attach
          ;; cache_control. Anthropic accepts both shapes.
          (set body.system [{:type :text :text context.system-prompt
                             :cache_control CACHE-CONTROL-1H}])
          (set body.system context.system-prompt)))
    (when (and context.tools (> (length context.tools) 0))
      (let [tools (convert-tools context.tools)]
        (when cache?
          (set (. tools (length tools) :cache_control) CACHE-CONTROL-1H))
        (set body.tools tools)
        (set body.tool_choice
             {:type :auto
              :disable_parallel_tool_use (not (parallel-tool-calls? options))})))
    (when cache?
      (mark-last-message-cache! wire-messages))
    (when (and options options.thinking-budget)
      (set body.thinking
           {:type :enabled :budget_tokens options.thinking-budget}))
    body))

(fn request-headers [api-key version streaming?]
  (let [headers [(.. "x-api-key: " (or api-key ""))
                 (.. "anthropic-version: " version)
                 "Content-Type: application/json"]]
    (when streaming?
      (table.insert headers 1 "Accept: text/event-stream"))
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
        version (or opts.anthropic-version DEFAULT-VERSION)
        max-tokens (or opts.max-tokens 16384)
        body (build-body model context max-tokens opts)
        curl (require :cURL)
        chunks []
        easy (curl.easy)]
    (configure-easy! easy base-url body (request-headers api-key version false) opts
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

(fn decode-partial-json [s]
  (if (or (= s nil) (= s ""))
      {}
      (let [(ok? value) (pcall json.decode s)]
        (if ok? value
            (do (log.warn (.. "anthropic_messages: bad streamed tool args JSON: "
                              (tostring value)))
                {})))))

(fn usage-from-anthropic [usage]
  (let [u (or usage {})]
    {:input (or u.input_tokens 0)
     :output (or u.output_tokens 0)
     :cache-read (or u.cache_read_input_tokens 0)
     :cache-write (or u.cache_creation_input_tokens 0)
     :total-tokens (+ (or u.input_tokens 0) (or u.output_tokens 0))}))

(fn merge-usage! [state usage]
  (when usage
    (let [u (usage-from-anthropic usage)]
      ;; Streaming `message_delta.usage` often contains only output_tokens.
      ;; Preserve input/cache counts from message_start when omitted later.
      (when (> u.input 0) (set state.usage.input u.input))
      (when (> u.output 0) (set state.usage.output u.output))
      (when (> u.cache-read 0) (set state.usage.cache-read u.cache-read))
      (when (> u.cache-write 0) (set state.usage.cache-write u.cache-write))
      (set state.usage.total-tokens (+ (or state.usage.input 0)
                                       (or state.usage.output 0))))))

(fn new-stream-state [model]
  {:model model
   :content []
   :blocks {}
   :usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}
   :stop-reason :stop
   :error-message nil})

(fn content-index-for-wire-index [wire-index]
  (+ (or wire-index 0) 1))

(fn start-stream-block! [state ev emit]
  (let [wire-index (or ev.index 0)
        idx (content-index-for-wire-index wire-index)
        b ev.content_block]
    (if (= (?. b :type) :text)
        (let [block (types.text-block (or b.text ""))]
          (table.insert state.content block)
          (tset state.blocks wire-index block)
          (when emit (emit {:type :text-start :content-index idx}))
          (when (not= block.text "")
            (when emit (emit {:type :text-delta :content-index idx :delta block.text}))))
        (= (?. b :type) :thinking)
        (let [block (types.thinking-block
                      {:thinking (or b.thinking "")
                       :thinking-signature b.signature
                       :redacted false})]
          (table.insert state.content block)
          (tset state.blocks wire-index block)
          (when emit (emit {:type :thinking-start :content-index idx}))
          (when (not= block.thinking "")
            (when emit (emit {:type :thinking-delta :content-index idx :delta block.thinking}))))
        (= (?. b :type) :tool_use)
        (let [block (types.tool-call-block b.id b.name (or b.input {}))]
          (set block.partial-json "")
          (table.insert state.content block)
          (tset state.blocks wire-index block)
          (when emit (emit {:type :tool-call-start :content-index idx})))
        nil)))

(fn delta-stream-block! [state ev emit]
  (let [wire-index (or ev.index 0)
        idx (content-index-for-wire-index wire-index)
        block (. state.blocks wire-index)
        d ev.delta]
    (when (and block d)
      (if (and (= block.type :text) (= d.type :text_delta))
          (do (set block.text (.. block.text (or d.text "")))
              (when emit (emit {:type :text-delta :content-index idx :delta (or d.text "")})))
          (and (= block.type :thinking) (= d.type :thinking_delta))
          (do (set block.thinking (.. block.thinking (or d.thinking "")))
              (when emit (emit {:type :thinking-delta :content-index idx :delta (or d.thinking "")})))
          (and (= block.type :thinking) (= d.type :signature_delta))
          (set block.thinking-signature d.signature)
          (and (= block.type :tool-call) (= d.type :input_json_delta))
          (let [chunk (or d.partial_json "")]
            (set block.partial-json (.. (or block.partial-json "") chunk))
            (when emit (emit {:type :tool-call-delta :content-index idx :delta chunk})))
          nil))))

(fn stop-stream-block! [state ev emit]
  (let [wire-index (or ev.index 0)
        idx (content-index-for-wire-index wire-index)
        block (. state.blocks wire-index)]
    (when block
      (if (= block.type :text)
          (when emit (emit {:type :text-end :content-index idx :content block.text}))
          (= block.type :thinking)
          (when emit (emit {:type :thinking-end :content-index idx :content block.thinking}))
          (= block.type :tool-call)
          (do (when (and block.partial-json (not= block.partial-json ""))
                (set block.arguments (decode-partial-json block.partial-json)))
              (set block.partial-json nil)
              (when emit (emit {:type :tool-call-end :content-index idx :tool-call block})))))))

(fn process-stream-event! [state ev emit]
  "Consume one decoded Anthropic Messages stream event table."
  (let [etype ev.type]
    (if (= etype :message_start)
        (merge-usage! state (?. ev :message :usage))
        (= etype :content_block_start)
        (start-stream-block! state ev emit)
        (= etype :content_block_delta)
        (delta-stream-block! state ev emit)
        (= etype :content_block_stop)
        (stop-stream-block! state ev emit)
        (= etype :message_delta)
        (do
          (merge-usage! state ev.usage)
          (when (?. ev :delta :stop_reason)
            (let [(stop err) (map-stop-reason ev.delta.stop_reason)]
              (set state.stop-reason stop)
              (set state.error-message err))))
        (= etype :message_stop)
        nil
        (= etype :error)
        (do (set state.stop-reason :error)
            (set state.error-message (or (?. ev :error :message)
                                         (?. ev :error :type)
                                         "Anthropic stream error")))
        nil))
  state)

(fn finalize-stream-state [state emit]
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
        version (or opts.anthropic-version DEFAULT-VERSION)
        max-tokens (or opts.max-tokens 16384)
        body (build-body model context max-tokens opts)
        curl (require :cURL)
        chunks []
        state (new-stream-state model)
        parser-error {:message nil}
        parser (sse.new-parser
                 (fn [frame]
                   (when (and (not parser-error.message)
                              (not= frame.data ""))
                     (let [(ok? decoded) (pcall json.decode frame.data)]
                       (if ok?
                           (process-stream-event! state decoded on-event)
                           (set parser-error.message decoded))))))
        easy (curl.easy)]
    (set body.stream true)
    (configure-easy! easy base-url body (request-headers api-key version true) opts
                     (fn [chunk]
                       (table.insert chunks chunk)
                       (parser.feed chunk)
                       (length chunk)))
    (values easy chunks state parser parser-error)))

(fn finalize-stream [easy chunks state parser parser-error model on-event ok? err]
  "Shared post-perform handling for the streaming pipeline."
  (let [status (easy:getinfo_response_code)]
    (easy:close)
    (when ok? (parser.finish))
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
              asst (types.assistant-error API PROVIDER model
                                          (.. "HTTP " status ": " raw))]
          (log.error (.. "http " status ": " raw))
          (when on-event (on-event {:type :error :message asst}))
          asst)
        (finalize-stream-state state on-event))))

(fn complete [model context options ?on-event ?yield-fn]
  "Single entry. Routes by ?on-event / ?yield-fn:
     - `?on-event` set → native streaming pipeline (typed SSE), driving
       curl cooperatively when ?yield-fn is given, blocking otherwise.
     - `?on-event` nil → non-streaming POST. Cooperative when ?yield-fn is
       given, blocking otherwise.
   Returns a canonical AssistantMessage in every case; on transport or
   HTTP failure the message has stop-reason :error with error-message set."
  (if ?on-event
      (let [(easy chunks state parser parser-error)
            (make-stream-request model context options ?on-event)]
        (?on-event {:type :start})
        (let [(ok? err) (if ?yield-fn
                            (http.perform-coop easy ?yield-fn)
                            (pcall #(easy:perform)))]
          (finalize-stream easy chunks state parser parser-error
                           model ?on-event ok? err)))
      (let [(easy chunks) (make-request model context options)
            (ok? err) (if ?yield-fn
                          (http.perform-coop easy ?yield-fn)
                          (pcall #(easy:perform)))
            status (easy:getinfo_response_code)]
        (easy:close)
        (response->assistant model chunks status ok? err))))

{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 :default-version DEFAULT-VERSION
 : convert-messages
 : convert-tools
 : map-stop-reason
 : parse-response
 : process-stream-event!
 : finalize-stream-state
 : build-body
 : complete}
