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
(local diagnostics (require :fen.core.diagnostics))
(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local http (require :fen.util.http))
(local path (require :fen.util.path))
(local sse (require :fen.util.sse))
(local text-util (require :fen.util.text))

(local TRACE-PATH (os.getenv :FEN_OPENAI_RESPONSES_TRACE))

(fn trace-event! [label event]
  "Opt-in raw Responses/Codex event tracing for live provider debugging.
   Set FEN_OPENAI_RESPONSES_TRACE to '-' for stderr or to a file path.
   The trace can contain prompt/output/encrypted reasoning payloads, so it is
   intentionally disabled by default."
  (when (and TRACE-PATH (not= TRACE-PATH ""))
    (let [line (.. (json.encode {: label :event event}) "\n")]
      (if (= TRACE-PATH "-")
          (log.debug (.. "openai-responses " line))
          (let [fh (io.open TRACE-PATH "a")]
            (when fh
              (fh:write line)
              (fh:close)))))))

;; ----------------------------------------------------------------
;; Provider failure diagnostics
;; ----------------------------------------------------------------

(local FULL-FAILURE-DUMP (os.getenv :FEN_PROVIDER_FAILURE_DUMP_FULL))
(local FAILURE-DIR-ENV (os.getenv :FEN_PROVIDER_FAILURE_DIR))
(local SENSITIVE-HEADERS
  {:authorization true
   :cookie true
   :set-cookie true
   :chatgpt-account-id true
   :openai-organization true
   :openai-project true})

(fn full-failure-dump? []
  (and FULL-FAILURE-DUMP (not= FULL-FAILURE-DUMP "") (not= FULL-FAILURE-DUMP "0")))

(fn table-length [xs]
  (if (= (type xs) :table) (length xs) 0))

(fn redact-headers [headers]
  "Copy HTTP headers with credentials/account identifiers redacted."
  (let [out {}]
    (each [k v (pairs (or headers {}))]
      (let [name (string.lower (tostring k))]
        (tset out k (if (. SENSITIVE-HEADERS name)
                        "[redacted]"
                        (tostring v)))))
    out))

(fn text-len [s]
  (if (= (type s) :string) (length s) 0))

(fn contains? [s needle]
  (and (= (type s) :string)
       (not= (string.find s needle 1 true) nil)))

(fn repaired-output? [s]
  (contains? s "[fen: tool output sanitized:"))

(fn truncated-output? [s]
  (contains? s "[fen: tool output truncated:"))

(fn content-summary [parts]
  (let [out []]
    (each [_ p (ipairs (or parts []))]
      (let [entry {:type (?. p :type)}]
        (when (?. p :text) (set entry.text-length (text-len p.text)))
        (when (?. p :refusal) (set entry.refusal-length (text-len p.refusal)))
        (when (?. p :annotations) (set entry.annotations-count (table-length p.annotations)))
        (table.insert out entry)))
    out))

(fn input-item-summary [item index]
  "Return a redacted, index-preserving summary of one Responses input item."
  (let [out {:index index
             :type (?. item :type)
             :role (?. item :role)}]
    (when (?. item :id) (set out.id item.id))
    (when (?. item :call_id) (set out.call-id item.call_id))
    (when (?. item :name) (set out.name item.name))
    (when (?. item :status) (set out.status item.status))
    (when (?. item :arguments) (set out.arguments-length (text-len item.arguments)))
    (when (?. item :output)
      (set out.output-length (text-len item.output))
      (when (repaired-output? item.output)
        (set out.output-sanitized? true))
      (when (truncated-output? item.output)
        (set out.output-truncated? true)))
    (when (?. item :encrypted_content) (set out.has-encrypted-content? true))
    (when (?. item :summary) (set out.summary-count (table-length item.summary)))
    (when (?. item :content) (set out.content (content-summary item.content)))
    out))

(fn tool-summary [tool index]
  {:index index
   :type (?. tool :type)
   :name (?. tool :name)
   :has-parameters? (not= (?. tool :parameters) nil)
   :strict (?. tool :strict)})

(fn function-output-stats [items]
  "Return redacted aggregate diagnostics for function_call_output entries."
  (let [out {:count 0
             :max-output-length 0
             :cumulative-output-length 0
             :sanitized-count 0
             :truncated-count 0
             :affected []}]
    (each [i item (ipairs (or items []))]
      (when (= (?. item :type) :function_call_output)
        (let [len (text-len item.output)
              sanitized? (repaired-output? item.output)
              truncated? (truncated-output? item.output)]
          (set out.count (+ out.count 1))
          (set out.cumulative-output-length (+ out.cumulative-output-length len))
          (when (> len out.max-output-length)
            (set out.max-output-length len))
          (when sanitized?
            (set out.sanitized-count (+ out.sanitized-count 1)))
          (when truncated?
            (set out.truncated-count (+ out.truncated-count 1)))
          (when (or sanitized? truncated?)
            (table.insert out.affected
                          {:index i
                           :call-id (?. item :call_id)
                           :output-length len
                           :sanitized? sanitized?
                           :truncated? truncated?})))))
    out))

(fn summarize-body [body]
  "Summarize a Responses request body without prompt/tool-result text."
  (let [out {:model (?. body :model)
             :stream (?. body :stream)
             :store (?. body :store)
             :input-count (table-length (?. body :input))
             :tools-count (table-length (?. body :tools))}]
    (when (?. body :instructions)
      (set out.instructions-length (text-len body.instructions)))
    (when (?. body :max_output_tokens)
      (set out.max-output-tokens body.max_output_tokens))
    (when (?. body :reasoning) (set out.reasoning body.reasoning))
    (when (?. body :text) (set out.text body.text))
    (when (?. body :include) (set out.include body.include))
    (when (?. body :service_tier) (set out.service-tier body.service_tier))
    (when (?. body :prompt_cache_key) (set out.prompt-cache-key "[redacted]"))
    (when (?. body :tool_choice) (set out.tool-choice body.tool_choice))
    (when (not= (?. body :parallel_tool_calls) nil)
      (set out.parallel-tool-calls body.parallel_tool_calls))
    (let [input (?. body :input)
          items []]
      (each [i item (ipairs (or input []))]
        (table.insert items (input-item-summary item i)))
      (set out.input items)
      (let [function-outputs (function-output-stats input)]
        (when (> function-outputs.count 0)
          (set out.function-call-outputs function-outputs))))
    (let [tools []]
      (each [i tool (ipairs (or (?. body :tools) []))]
        (table.insert tools (tool-summary tool i)))
      (set out.tools tools))
    out))

(fn decode-body [body]
  (when (= (type body) :string)
    (let [(ok? decoded) (pcall json.decode body)]
      (if ok? decoded {:decode-error (tostring decoded)
                       :raw-length (length body)}))))

(fn failure-dir []
  (if (and FAILURE-DIR-ENV (not= FAILURE-DIR-ENV ""))
      FAILURE-DIR-ENV
      (.. (path.state-dir :fen) "/provider-failures")))

(fn ensure-dir! [dir]
  (os.execute (.. "mkdir -p " (path.shell-quote dir)))
  (path.dir-exists? dir))

(fn safe-name [s]
  (let [(out _) (string.gsub (tostring (or s "unknown")) "[^%w%._%-]+" "-")]
    out))

(fn diagnostic-path [api provider model]
  (let [dir (failure-dir)
        fallback "/tmp/fen-provider-failures"
        root (if (ensure-dir! dir)
                 dir
                 (if (ensure-dir! fallback) fallback nil))]
    (when root
      (.. root "/"
          (safe-name api) "-" (safe-name provider) "-" (safe-name model) "-"
          (os.date "!%Y%m%dT%H%M%SZ") "-" (tostring (math.random 100000 999999))
          ".json"))))

(fn failure-diagnostic [api provider model resp ?request-opts reason]
  "Build a JSON-serializable provider failure diagnostic. The default body
   capture is redacted to structure/lengths; set FEN_PROVIDER_FAILURE_DUMP_FULL=1
   before starting fen to include the exact request body."
  (let [body (decode-body (?. ?request-opts :body))
        request {:method (?. ?request-opts :method)
                 :url (?. ?request-opts :url)
                 :headers (redact-headers (?. ?request-opts :headers))
                 :body-summary (summarize-body body)}]
    (when (full-failure-dump?)
      (set request.body body))
    (let [doc {:timestamp (os.date "!%Y-%m-%dT%H:%M:%SZ")
               :api api
               :provider provider
               :model model
               :reason reason
               :http {:status (?. resp :status)
                      :error (?. resp :error)
                      :curl-code (?. resp :curl-code)
                      :body (?. resp :body)
                      :headers (redact-headers (?. resp :headers))}
               :request request}
          runtime (diagnostics.runtime-info)]
      (when runtime (set doc.runtime runtime))
      doc)))

(fn write-failure-diagnostic! [api provider model resp ?request-opts reason]
  "Persist a redacted provider failure diagnostic and return its path."
  (let [file (diagnostic-path api provider model)]
    (if (not file)
        (do (log.error "provider failure diagnostic: could not create state or /tmp directory")
            nil)
        (let [doc (failure-diagnostic api provider model resp ?request-opts reason)
              (ok? encoded) (pcall json.encode doc)]
          (if (not ok?)
              (do (log.error (.. "provider failure diagnostic: encode failed: " (tostring encoded)))
                  nil)
              (let [fh (io.open file "w")]
                (if (not fh)
                    (do (log.error (.. "provider failure diagnostic: could not open " file))
                        nil)
                    (do
                      (fh:write encoded)
                      (fh:write "\n")
                      (fh:close)
                      (log.error (.. "provider failure diagnostic: " file))
                      file))))))))

(fn attach-diagnostic! [asst path]
  "Append a diagnostic file path to a provider error AssistantMessage."
  (when (and asst path)
    (let [suffix (.. "\nDiagnostic: " path)]
      (set asst.error-message (.. (tostring (or asst.error-message "")) suffix))
      (let [block (. asst.content 1)]
        (when (and block (= block.type :text))
          (set block.text (.. (tostring (or block.text "")) suffix))))))
  asst)

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

(fn non-empty-string [x]
  ;; Keywords compile to Lua strings, so this also covers :api/:provider.
  (and (= (type x) :string) (not= x "") x))

(fn dim-differs? [a b]
  "True only when both sides are known (non-empty) and differ. Unknown on
   either side ⇒ false, so partial request identity never over-strips."
  (let [x (non-empty-string a)
        y (non-empty-string b)]
    (and x y (not= x y) true)))

(fn foreign-turn? [m id]
  "True when a persisted assistant turn came from a different model or
   backend than the request `id` ({:model :api :provider}). Responses
   rs_/fc_ ids are scoped to the model+backend that produced them; replaying
   them elsewhere trips OpenAI's reasoning↔call pairing validation for a
   permanent store:false 400. Conservative (see dim-differs?): missing
   request or turn identity never triggers the repair."
  (or (dim-differs? m.model id.model)
      (dim-differs? m.api id.api)
      (dim-differs? m.provider id.provider)))

(fn convert-assistant-block [block msg-index drop-fc-id?]
  "Returns one Responses input item for an assistant content block, or nil
   to skip. Thinking blocks only round-trip when their :thinking-signature
   is the JSON-encoded ResponseReasoningItem we stored at end-of-stream;
   without it the API rejects the message. `drop-fc-id?` (set when the
   owning turn came from a different model) omits the `fc_` function-call
   item id: OpenAI pairs each `fc_xxx` id with the `rs_xxx` reasoning item
   from the turn that produced it, so replaying another model's `fc_` id
   triggers that pairing validation. Keeping only `call_id` sidesteps it
   (mirrors pi-mono openai-responses-shared.ts)."
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
        (when (and item-id (not= item-id "")
                   (not (and drop-fc-id? (string.match item-id "^fc_"))))
          (set out.id item-id))
        out)
      nil))

(fn convert-tool-result-message [m]
  (let [text-result (text-of-content m.content)
        repaired (text-util.scrub-tool-text text-result)
        (call-id _) (split-compound-id m.tool-call-id)]
    {:type :function_call_output
     :call_id call-id
     :output repaired.text}))

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
;; signature: (convert-messages messages ?id) -> [ResponseInputItem]
;; summary: Convert canonical transcript messages into Responses input items, repairing persisted shapes that would otherwise 4xx forever (cross-model/cross-backend fc_/rs_ ids, lone reasoning items, orphaned tool outputs, reasoning-less tool-call turns).
;; tags: provider openai responses messages
(fn convert-messages [messages ?id]
  "Canonical Messages → Responses ResponseInput list. The system prompt
   rides in the request body's `instructions`, not here. Thinking blocks
   without a serialized ResponseReasoningItem signature are skipped.

   `store` is hard-coded false, so an invalid input shape is an
   unrecoverable HTTP 400 that the agent loop replays every turn — one bad
   persisted message wedges the session forever. Four shapes are repaired:

   1. Cross-model/backend replay (gated on request `?id`
      {:model :api :provider}): drop the turn's `fc_` ids and reasoning
      items. fc_/rs_ ids are scoped to the model+backend that produced
      them; replaying foreign ones trips OpenAI pairing validation.
   2. Lone/trailing reasoning: a reasoning item with no later
      message/function_call in the turn is rejected (\"provided without
      its required following item\").
   3. Orphaned/duplicate function_call_output: emit a result only while
      its call is still pending (see the tool-result branch).
   4. Reasoning-less tool-call turn: a turn that ends up with
      function_call items but no surviving reasoning item (the stream
      dropped its rs_, or #1/#2 removed it) has its `fc_` ids stripped
      (keeping `call_id`). The store:false Codex backend pairs each fc_
      with its turn's rs_; replaying fc_ without rs_ 400s forever (#132).
      Same sidestep as #1, mirrors pi-mono.

   Existing forward repair is kept: a function_call with no result gets a
   synthetic placeholder output at message boundaries. #2/#3 always apply;
   #1/#4 need `?id`, so the one-arg form is unchanged for well-formed
   same-backend transcripts."
  (let [out []
        pending []
        id (or ?id {})]
    (var msg-index 0)
    (each [_ m (ipairs (or messages []))]
      (when (and (> (length pending) 0) (not= m.role :tool-result))
        (flush-pending! out pending))
      (if (= m.role :user)
          (table.insert out (convert-user-message m))
          (= m.role :assistant)
          (let [different? (foreign-turn? m id)
                items []]
            (each [_ block (ipairs (or m.content []))]
              (let [item (convert-assistant-block block msg-index different?)]
                (when item (table.insert items item))))
            ;; Keep a reasoning item only if a later message/function_call
            ;; follows it in the turn; foreign turns drop reasoning outright.
            (var last-output 0)
            (each [i it (ipairs items)]
              (when (or (= it.type :message) (= it.type :function_call))
                (set last-output i)))
            (let [start (length out)]
              (var reasoning-survived? false)
              (var fc-count 0)
              (each [i it (ipairs items)]
                (let [drop? (and (= it.type :reasoning)
                                 (or different? (>= i last-output)))]
                  (when (not drop?)
                    (table.insert out it)
                    (when (= it.type :reasoning)
                      (set reasoning-survived? true))
                    (when (= it.type :function_call)
                      (set fc-count (+ fc-count 1))
                      (table.insert pending it.call_id)))))
              ;; Repair #4: a same-backend turn that emitted function_call
              ;; items but no surviving reasoning item replays its fc_ ids
              ;; unrecoverably. Strip the fc_ item id, keeping call_id.
              ;; Gated on request `?id` like #1 (conservative: unknown
              ;; request identity never over-strips; production always
              ;; threads ?id, so live Codex/Responses calls are repaired).
              (when (and ?id (not reasoning-survived?) (> fc-count 0))
                (for [k (+ start 1) (length out)]
                  (let [it (. out k)]
                    (when (= it.type :function_call)
                      (set it.id nil)))))))
          (= m.role :tool-result)
          (let [item (convert-tool-result-message m)]
            ;; Emit only while the call is still pending. remove-pending!
            ;; is true exactly then; false for an orphan, a duplicate, or a
            ;; result arriving after a synthesized placeholder — each of
            ;; which would 400 and wedge the session.
            (if (remove-pending! pending item.call_id)
                (table.insert out item)
                nil)))
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
   :current-block nil
   ;; True once any terminal event (response.completed/failed, or a top-level
   ;; error) is seen. A 200 stream that closes without one is an incomplete
   ;; response, not a silent empty success — finalize-stream turns it into an
   ;; error rather than an empty :stop turn.
   :saw-terminal? false
   ;; rs_ ids of reasoning items captured during streaming, so the terminal
   ;; response.completed can detect (and recover) any the stream dropped.
   :seen-reasoning-ids {}})

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

(fn start-thinking-block! [state item emit]
  (finish-current-block! state emit)
  (set state.current-item item)
  (let [block (types.thinking-block {:thinking ""})]
    (table.insert state.content block)
    (set state.current-block block)
    (when emit (emit {:type :thinking-start
                      :content-index (current-content-index state)}))
    block))

(fn handle-output-item-added! [state item emit]
  (finish-current-block! state emit)
  (when (table? item)
    (set state.current-item item)
    (if (= item.type :reasoning)
        (do
          (when item.id (tset state.seen-reasoning-ids item.id true))
          (start-thinking-block! state item emit))
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
  (let [text (string-or-empty delta)]
    (when (not= text "")
      (let [block (if (and state.current-block
                           (= state.current-block.type :thinking))
                      state.current-block
                      (start-thinking-block! state {:type :reasoning} emit))]
        (set block.thinking (.. block.thinking text))
        (when emit
          (emit {:type :thinking-delta
                 :content-index (current-content-index state)
                 :delta text}))))))

(fn handle-thinking-done! [state text emit]
  (let [final (string-or-empty text)]
    (when (not= final "")
      (let [block (if (and state.current-block
                           (= state.current-block.type :thinking))
                      state.current-block
                      (start-thinking-block! state {:type :reasoning} emit))]
        (set block.thinking final)))))

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

(fn join-reasoning-content-parts [parts]
  (let [out []]
    (each [_ p (ipairs (array-or-empty parts))]
      (when (table? p)
        (table.insert out (string-or-empty p.text))))
    (table.concat out "\n\n")))

(fn finalize-reasoning-block! [block item]
  (let [summary (join-summary-parts (field item :summary))
        content (join-reasoning-content-parts (field item :content))]
    (if (not= summary "")
        (set block.thinking summary)
        (not= content "")
        (set block.thinking content)))
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
    (when (and (= item.type :reasoning) item.id)
      (tset state.seen-reasoning-ids item.id true))
    (let [block state.current-block]
      (if (and (= item.type :reasoning) block (= block.type :thinking))
          (finalize-reasoning-block! block item)
          (= item.type :reasoning)
          (finalize-reasoning-block! (start-thinking-block! state item emit) item)
          (and (= item.type :message) block (= block.type :text))
          (finalize-message-block! block item)
          (and (= item.type :function_call) block (= block.type :tool-call))
          (finalize-tool-call-block! block item))))
  (finish-current-block! state emit))

(fn number-or-zero [x]
  (if (= (type x) :number) x 0))

(fn reasoning-output-missing? [state output]
  "True iff response.output carries a reasoning item whose id the stream
   never captured — the exact poison shape (a function_call turn whose rs_
   reasoning was dropped). Gates reconcile-dropped-reasoning! so the
   well-tested streamed path stays a strict no-op."
  (var missing? false)
  (each [_ it (ipairs (array-or-empty output))]
    (when (and (table? it)
               (= (field it :type) :reasoning)
               (field it :id)
               (not (. state.seen-reasoning-ids (field it :id))))
      (set missing? true)))
  missing?)

(fn reconcile-dropped-reasoning! [state output]
  "Rebuild state.content in response.output order, synthesizing a finalized
   thinking block (encrypted signature included) for any reasoning item the
   stream dropped, positioned before its function_call(s). Conservative: if
   the streamed blocks do not line up 1:1 with output's non-dropped items
   (or any streamed block is left over), leave state.content untouched —
   never regress the streamed path."
  (let [streamed state.content
        rebuilt []]
    (var si 1)
    (var ok? true)
    (each [_ it (ipairs (array-or-empty output))]
      (when ok?
        (let [it-type (and (table? it) (field it :type))]
          (if (= it-type :reasoning)
              (let [rid (field it :id)]
                (if (and rid (. state.seen-reasoning-ids rid))
                    (let [blk (. streamed si)]
                      (if (and (table? blk) (= blk.type :thinking))
                          (do (table.insert rebuilt blk) (set si (+ si 1)))
                          (set ok? false)))
                    (let [blk (types.thinking-block {:thinking ""})]
                      (finalize-reasoning-block! blk it)
                      (table.insert rebuilt blk))))
              (let [blk (. streamed si)]
                (if (and (table? blk) (not= blk.type :thinking))
                    (do (table.insert rebuilt blk) (set si (+ si 1)))
                    (set ok? false)))))))
    (when (and ok? (> si (length streamed)))
      (set state.content rebuilt)
      ;; streaming is over; drop pointers so finalize-stream-state's
      ;; finish-current-block! is a no-op against the rebuilt content.
      (set state.current-block nil)
      (set state.current-item nil))))

(fn handle-completed! [state response]
  (set state.saw-terminal? true)
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
      (set state.error-message err))
    ;; Recover any reasoning item the stream dropped (parallel tool-call
    ;; turns, or turns following a mid-stream error): without its rs_ item
    ;; the turn's fc_ ids 400 forever on the store:false Codex backend (#132).
    (let [output (field response :output)]
      (when (and (table? output)
                 (> (length output) 0)
                 (reasoning-output-missing? state output))
        (reconcile-dropped-reasoning! state output)))))

(fn handle-failed! [state response]
  (set state.saw-terminal? true)
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
  (set state.saw-terminal? true)
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

    :response.reasoning_summary_text.done
    (handle-thinking-done! state (field event :text) emit)

    :response.reasoning_summary_part.done
    (handle-thinking-delta! state "\n\n" emit)

    :response.reasoning_text.delta
    (handle-thinking-delta! state (string-or-empty (field event :delta)) emit)

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

    ;; Terminal incomplete response (e.g. max_output_tokens). handle-completed!
    ;; maps response.status :incomplete -> :length. Codex aliases this to
    ;; response.completed upstream; vanilla Responses emits it directly.
    :response.incomplete
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
;; signature: (build-body model context max-tokens options ?id) -> table
;; summary: Build a streaming Responses request body from canonical context, provider options, tools, reasoning settings, and prompt cache keys.
;; tags: provider openai responses request
(fn build-body [model context max-tokens options ?id]
  "Build a Responses request body. The system prompt rides in `instructions`,
   not in `input`. `options` is the flat per-call options table — it
   carries provider knobs like `:reasoning-effort`, `:verbosity`,
   `:include`, `:service-tier`, `:prompt-cache-key`, and `:temperature`.
   `?id` ({:model :api :provider}) is passed to `convert-messages` so it
   can repair persisted cross-model/backend transcript shapes."
  (let [opts (or options {})
        body {: model
              :store false
              :stream true
              :input (convert-messages context.messages ?id)}]
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
                           (do
                             (trace-event! :decoded decoded)
                             (let [mapped (if event-mapper
                                              (event-mapper decoded)
                                              decoded)]
                               (when mapped
                                 (when (not= mapped decoded)
                                   (trace-event! :mapped mapped))
                                 (process-event! state mapped on-event)))))))))]
    (values state parser parser-error)))

;; @doc fen.extensions.provider_openai.openai_responses_shared.build-request-opts
;; kind: function
;; signature: (build-request-opts model context options on-chunk ?headers-override ?url-override default-base-url responses-path ?id) -> table
;; summary: Assemble fen.util.http options for a streaming OpenAI-compatible Responses POST.
;; tags: provider openai responses http
(fn build-request-opts [model context options on-chunk ?headers-override ?url-override default-base-url responses-path ?id]
  (let [opts (or options {})
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url default-base-url)
        url (or ?url-override (build-url base-url responses-path))
        max-tokens (or opts.max-tokens 16384)
        body (build-body model context max-tokens opts ?id)]
    {:method :POST
     : url
     :headers (or ?headers-override (request-headers api-key))
     :body (json.encode body)
     :timeout-ms (or opts.timeout-ms 600000)
     :connect-timeout-ms (or opts.connect-timeout-ms 30000)
     :idle-timeout-ms opts.idle-timeout-ms
     : on-chunk}))

;; @doc fen.extensions.provider_openai.openai_responses_shared.finalize-stream
;; kind: function
;; signature: (finalize-stream state parser parser-error api provider model resp on-event) -> AssistantMessage
;; summary: Finish a Responses SSE stream, preserving the calling provider's canonical API/provider identity.
;; tags: provider openai responses streaming
(fn finalize-stream [state parser parser-error api provider model resp on-event ?request-opts]
  (when (not resp.error) (parser.finish))
  (if resp.error
      (let [path (write-failure-diagnostic! api provider model resp ?request-opts :transport)
            msg (if path (.. resp.error "\nDiagnostic: " path) resp.error)
            asst (types.assistant-error api provider model msg)]
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (not= parser-error.message nil)
      (let [diag-resp {:status resp.status :body resp.body :headers resp.headers
                       :error (tostring parser-error.message)}
            path (write-failure-diagnostic! api provider model diag-resp ?request-opts :parser)
            msg (if path (.. (tostring parser-error.message) "\nDiagnostic: " path)
                    parser-error.message)
            asst (types.assistant-error api provider model msg)]
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (or (< resp.status 200) (>= resp.status 300))
      (let [path (write-failure-diagnostic! api provider model resp ?request-opts :http)
            err (.. "HTTP " resp.status ": " resp.body)
            msg (if path (.. err "\nDiagnostic: " path) err)
            asst (types.assistant-error api provider model msg)]
        (log.error (.. "http " resp.status ": " resp.body))
        (when on-event (on-event {:type :error :message asst}))
        asst)
      ;; A 2xx whose stream closed without any terminal event
      ;; (response.completed/failed or a top-level error) is an incomplete
      ;; response: the connection dropped mid-stream or the body was empty.
      ;; Surface it as an error instead of an empty :stop turn the agent loop
      ;; would treat as a silent natural stop. Partial content is discarded.
      (not state.saw-terminal?)
      (let [diag-resp {:status resp.status :body resp.body :headers resp.headers
                       :error "stream ended without a completion event"}
            path (write-failure-diagnostic! api provider model diag-resp ?request-opts :incomplete)
            err "stream ended without a completion event"
            msg (if path (.. err "\nDiagnostic: " path) err)
            asst (types.assistant-error api provider model msg)]
        (log.error "openai-responses: stream ended without a completion event")
        (when on-event (on-event {:type :error :message asst}))
        asst)
      (let [asst (finalize-stream-state state api provider on-event)]
        (when (= asst.stop-reason :error)
          (let [diag-resp {:status resp.status :body resp.body :headers resp.headers
                           :error asst.error-message}
                path (write-failure-diagnostic! api provider model diag-resp ?request-opts :stream)]
            (attach-diagnostic! asst path)))
        asst)))

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
 : write-failure-diagnostic!
 : failure-diagnostic
 : attach-diagnostic!
 : redact-headers
 : summarize-body
 : clamp-reasoning-effort
 : split-compound-id
 : parse-streaming-json}
