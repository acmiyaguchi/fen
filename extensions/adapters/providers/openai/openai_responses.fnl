;; OpenAI Responses API provider (api.openai.com/v1/responses).
;;
;; Mirrors pi-mono's `packages/ai/src/providers/openai-responses.ts` shape,
;; but always streams. The Responses endpoint and the Codex subscription
;; endpoint share the OpenAI-compatible reducer in
;; `fen.extensions.provider_openai.openai_responses_shared`; this module owns the
;; URL/headers/request-body for the public API and uses
;; OPENAI_API_KEY for auth.
;;
;; The blocking `complete` and cooperative `complete-coop` paths drive the
;; same SSE pipeline as `complete-stream`, just without forwarding events
;; to a caller. That keeps the provider's output canonical and matches
;; the agent loop's expectation that every provider returns the same
;; `AssistantMessage` shape.

(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local http (require :fen.util.http))
(local sse (require :fen.util.sse))
(local retry (require :fen.core.llm.retry))
(local compat (require :fen.extensions.provider_openai.openai_responses_shared))

(local API :openai-responses)
(local PROVIDER :openai)
(local DEFAULT-BASE-URL "https://api.openai.com/v1")
(local RESPONSES-PATH "/responses")
(local DEFAULT-TIMEOUT-MS 600000)
(local DEFAULT-CONNECT-TIMEOUT-MS 30000)

;; @doc fen.extensions.provider_openai.openai_responses.build-url
;; kind: function
;; signature: (build-url base-url) -> string
;; summary: Normalize an OpenAI base URL into the /responses endpoint while preserving already-qualified Responses URLs.
;; tags: provider openai responses http
(fn build-url [base-url]
  (compat.build-url base-url RESPONSES-PATH))

;; @doc fen.extensions.provider_openai.openai_responses.build-body
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
              :input (compat.convert-messages context.messages)}]
    (when (and context.system-prompt (not= context.system-prompt ""))
      (set body.instructions context.system-prompt))
    (when (and context.tools (> (length context.tools) 0))
      (set body.tools (compat.convert-tools context.tools))
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
           {:effort (compat.clamp-reasoning-effort model opts.reasoning-effort)
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

(fn retry-options [options ?on-event]
  (let [opts (or options {})
        env-retry (os.getenv :AGENT_FENNEL_RETRY)
        max-attempts (if (= env-retry "0")
                         1
                         (or opts.retry-max-attempts retry.DEFAULT-MAX-ATTEMPTS))]
    {:max-attempts max-attempts
     :base-delay-ms (or opts.retry-base-delay-ms retry.DEFAULT-BASE-DELAY-MS)
     :max-delay-ms (or opts.retry-max-delay-ms retry.DEFAULT-MAX-DELAY-MS)
     :on-retry (fn [ev]
                 (when ?on-event
                   (?on-event {:type :provider-retry
                               :provider PROVIDER
                               :attempt ev.attempt
                               :max-attempts (. ev :max-attempts)
                               :delay-ms (. ev :delay-ms)
                               :reason ev.reason})))}))

;; @doc fen.extensions.provider_openai.openai_responses.make-stream-pipeline
;; kind: function
;; signature: (make-stream-pipeline model on-event event-mapper) -> state, parser, parser-error
;; summary: Create the SSE parser and shared Responses stream reducer state for one streaming request, with optional Codex event mapping.
;; tags: provider openai responses streaming
(fn make-stream-pipeline [model on-event event-mapper]
  "Build a fresh (state parser parser-error) tuple for one streaming POST.
   `event-mapper` is optional (used by the Codex subscription provider to
   alias `response.done` / `response.incomplete` to `response.completed`)."
  (let [state (compat.new-stream-state model)
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
                               (compat.process-event! state mapped on-event))))))))]
    (values state parser parser-error)))

;; @doc fen.extensions.provider_openai.openai_responses.build-request-opts
;; kind: function
;; signature: (build-request-opts model context options on-chunk ?headers-override ?url-override) -> table
;; summary: Assemble fen.util.http options for a streaming Responses POST, allowing Codex to override auth headers and endpoint URL.
;; tags: provider openai responses http
(fn build-request-opts [model context options on-chunk ?headers-override ?url-override]
  "Assemble a fen.util.http opts table for a streaming Responses POST. The
   Codex provider reuses this by passing `?headers-override` (Codex auth
   headers) and `?url-override` (chatgpt.com endpoint)."
  (let [opts (or options {})
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (or ?url-override (build-url base-url))
        max-tokens (or opts.max-tokens 16384)
        body (build-body model context max-tokens opts)]
    {:method :POST
     : url
     :headers (or ?headers-override (request-headers api-key))
     :body (json.encode body)
     :timeout-ms (or opts.timeout-ms DEFAULT-TIMEOUT-MS)
     :connect-timeout-ms (or opts.connect-timeout-ms DEFAULT-CONNECT-TIMEOUT-MS)
     : on-chunk}))

;; @doc fen.extensions.provider_openai.openai_responses.finalize-stream
;; kind: function
;; signature: (finalize-stream state parser parser-error model resp on-event) -> AssistantMessage
;; summary: Finish the SSE parser, convert transport/parser/HTTP failures to assistant errors, or finalize shared Responses stream state.
;; tags: provider openai responses streaming
(fn finalize-stream [state parser parser-error model resp on-event]
  "Shared post-request handling for both vanilla and Codex streaming."
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
      (compat.finalize-stream-state state API PROVIDER on-event)))

;; @doc fen.extensions.provider_openai.openai_responses.complete
;; kind: function
;; signature: (complete model context options ?on-event ?yield-fn) -> AssistantMessage
;; summary: Execute one OpenAI Responses provider call through the streaming SSE pipeline with optional cooperative transport and event forwarding.
;; tags: provider openai responses complete
(fn complete [model context options ?on-event ?yield-fn]
  "Single entry. Always streams under the hood; transports differ —
   blocking when no yield-fn is given (print mode / tests), cooperative
   otherwise. `?on-event` is plumbed through for callers that want stream
   deltas; passing nil yields just the final AssistantMessage."
  (let [latest {:state nil :parser nil :parser-error nil}]
    (when ?on-event (?on-event {:type :start}))
    (let [resp (retry.with-retry
                 (retry-options options ?on-event)
                 (fn [_attempt]
                   (let [(state parser parser-error) (make-stream-pipeline model ?on-event nil)
                         req-opts (build-request-opts model context options
                                                      (fn [chunk] (parser.feed chunk)) nil nil)]
                     (set latest.state state)
                     (set latest.parser parser)
                     (set latest.parser-error parser-error)
                     (set req-opts.yield ?yield-fn)
                     (http.request req-opts)))
                 ?yield-fn)]
      (finalize-stream latest.state latest.parser latest.parser-error model resp ?on-event))))

;; @doc fen.extensions.provider_openai.openai_responses.api
;; kind: data
;; signature: keyword
;; summary: Provider API family keyword used by registry metadata for the OpenAI Responses adapter.
;; tags: provider openai responses metadata
;; @doc fen.extensions.provider_openai.openai_responses.provider
;; kind: data
;; signature: keyword
;; summary: Provider owner keyword used on canonical assistant messages emitted by the Responses adapter.
;; tags: provider openai responses metadata
;; @doc fen.extensions.provider_openai.openai_responses.default-base-url
;; kind: data
;; signature: string
;; summary: Default OpenAI v1 API root used by the Responses adapter before appending /responses.
;; tags: provider openai responses metadata
{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : build-body
 : build-request-opts
 : make-stream-pipeline
 : finalize-stream
 : complete}
