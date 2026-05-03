;; OpenAI Responses API provider (api.openai.com/v1/responses).
;;
;; Mirrors pi-mono's `packages/ai/src/providers/openai-responses.ts` shape,
;; but always streams. The Responses endpoint and the Codex subscription
;; endpoint share the reducer in `openai_responses_shared.fnl`; this module
;; owns the URL/headers/request-body for the public API and uses
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
(local shared (require :fen.extensions.provider_openai.openai_responses_shared))

(local API :openai-responses)
(local PROVIDER :openai)
(local DEFAULT-BASE-URL "https://api.openai.com/v1")
(local RESPONSES-PATH "/responses")
(local DEFAULT-TIMEOUT-MS 600000)
(local DEFAULT-CONNECT-TIMEOUT-MS 30000)

(fn ends-with? [s suffix]
  (let [n (length suffix)]
    (and (>= (length s) n)
         (= (string.sub s (- (length s) n -1)) suffix))))

(fn build-url [base-url]
  (if (ends-with? base-url RESPONSES-PATH)
      base-url
      (.. base-url RESPONSES-PATH)))

(fn build-body [model context max-tokens options]
  "Build a Responses request body. The system prompt rides in `instructions`,
   not in `input`. `options` is the flat per-call options table — it
   carries provider knobs like `:reasoning-effort`, `:verbosity`,
   `:include`, `:service-tier`, `:prompt-cache-key`, and `:temperature`."
  (let [opts (or options {})
        body {: model
              :store false
              :stream true
              :input (shared.convert-messages context.messages)}]
    (when (and context.system-prompt (not= context.system-prompt ""))
      (set body.instructions context.system-prompt))
    (when (and context.tools (> (length context.tools) 0))
      (set body.tools (shared.convert-tools context.tools))
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
           {:effort (shared.clamp-reasoning-effort model opts.reasoning-effort)
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

(fn make-stream-pipeline [model on-event event-mapper]
  "Build a fresh (state parser parser-error) tuple for one streaming POST.
   `event-mapper` is optional (used by the Codex subscription provider to
   alias `response.done` / `response.incomplete` to `response.completed`)."
  (let [state (shared.new-stream-state model)
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
                               (shared.process-event! state mapped on-event))))))))]
    (values state parser parser-error)))

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
      (shared.finalize-stream-state state API PROVIDER on-event)))

(fn complete [model context options ?on-event ?yield-fn]
  "Single entry. Always streams under the hood; transports differ —
   blocking when no yield-fn is given (print mode / tests), cooperative
   otherwise. `?on-event` is plumbed through for callers that want stream
   deltas; passing nil yields just the final AssistantMessage."
  (let [(state parser parser-error) (make-stream-pipeline model ?on-event nil)
        req-opts (build-request-opts model context options
                                     (fn [chunk] (parser.feed chunk)) nil nil)]
    (set req-opts.yield ?yield-fn)
    (when ?on-event (?on-event {:type :start}))
    (let [resp (http.request req-opts)]
      (finalize-stream state parser parser-error model resp ?on-event))))

{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : build-body
 : build-request-opts
 : make-stream-pipeline
 : finalize-stream
 : complete}
