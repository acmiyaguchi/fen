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

(local json (require :fen.util.json))
(local sse (require :fen.util.sse))
(local streaming (require :fen.extensions.provider_shared.streaming))
(local compat (require :fen.extensions.provider_openai.openai_responses_shared))

(local API :openai-responses)
(local PROVIDER :openai)
(local DEFAULT-BASE-URL "https://api.openai.com/v1")
(local RESPONSES-PATH "/responses")
(local DEFAULT-TIMEOUT-MS 600000)
(local DEFAULT-CONNECT-TIMEOUT-MS 30000)
(local ENCRYPTED-REASONING-INCLUDE "reasoning.encrypted_content")

(fn with-encrypted-reasoning [includes reasoning-effort?]
  "Return the `include` list with `reasoning.encrypted_content` added whenever
   reasoning is enabled (preserving any caller-provided entries). `store` is
   hard-coded false, so a reasoning item round-trips across a tool turn only if
   the server returns its encrypted payload and we replay it inline; without
   this the next turn replays a bare `rs_` id the store:false backend never
   persisted and 404s (#132). Mirrors the codex provider's DEFAULT-INCLUDE and
   pi-mono."
  (let [out (icollect [_ v (ipairs (or includes []))] v)]
    (when (and reasoning-effort?
               (not (accumulate [found false _ v (ipairs out) &until found]
                      (= v ENCRYPTED-REASONING-INCLUDE))))
      (table.insert out ENCRYPTED-REASONING-INCLUDE))
    out))

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
   `:include`, `:service-tier`, `:prompt-cache-key`, and `:temperature`.
   This provider's {:model :api :provider} identity is passed to
   `convert-messages` so it can repair persisted cross-model/backend
   transcript shapes."
  (let [opts (or options {})
        body {: model
              :store false
              :stream true
              :input (compat.convert-messages
                       context.messages {:model model :api API :provider PROVIDER})}]
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
    (let [includes (with-encrypted-reasoning opts.include opts.reasoning-effort)]
      (when (> (length includes) 0)
        (set body.include includes)))
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
     :idle-timeout-ms opts.idle-timeout-ms
     ;; Streaming success never reads resp.body; skip buffering the full SSE
     ;; stream (issue #167 M2). Only accumulate when no on-chunk sink exists.
     :accumulate-body? (= on-chunk nil)
     : on-chunk}))

;; @doc fen.extensions.provider_openai.openai_responses.finalize-stream
;; kind: function
;; signature: (finalize-stream state parser parser-error model resp on-event) -> AssistantMessage
;; summary: Finish the SSE parser, convert transport/parser/HTTP failures to assistant errors, or finalize shared Responses stream state.
;; tags: provider openai responses streaming
(fn finalize-stream [state parser parser-error model resp on-event ?request-opts]
  "Delegate to the shared Responses finalizer with this module's API/provider
   identity. Vanilla and Codex share one transport/parser/HTTP/diagnostic path."
  (compat.finalize-stream
    state parser parser-error API PROVIDER model resp on-event ?request-opts))

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
  (streaming.complete-streaming
    {:provider PROVIDER
     :model model
     :context context
     :options options
     :on-event ?on-event
     :yield-fn ?yield-fn
     :make-stream-pipeline (fn [model on-event]
                             (make-stream-pipeline model on-event nil))
     :build-request-opts (fn [model context options on-chunk]
                           (build-request-opts model context options on-chunk nil nil))
     :finalize-stream finalize-stream}))

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
