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

(local streaming (require :fen.extensions.provider_shared.streaming))
(local compat (require :fen.extensions.provider_openai.openai_responses_shared))

(local API :openai-responses)
(local PROVIDER :openai)
(local DEFAULT-BASE-URL "https://api.openai.com/v1")
(local RESPONSES-PATH "/responses")
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

;; @doc fen.extensions.provider_openai.openai_responses.merge-options
;; kind: function
;; signature: (merge-options opts) -> table
;; summary: Copy per-call options and add vanilla Responses defaults for encrypted reasoning includes.
;; tags: provider openai responses options
(fn merge-options [opts]
  "Return a copy of per-call options with vanilla Responses defaults applied.
   Request encrypted reasoning whenever reasoning is enabled so store:false
   reasoning items can round-trip across tool turns (#132)."
  (let [out {}]
    (each [k v (pairs (or opts {}))]
      (tset out k v))
    (set out.include (with-encrypted-reasoning out.include out.reasoning-effort))
    out))

;; @doc fen.extensions.provider_openai.openai_responses.build-body
;; kind: function
;; signature: (build-body model context max-tokens options) -> table
;; summary: Build a streaming Responses request body from canonical context, provider options, tools, reasoning settings, and prompt cache keys.
;; tags: provider openai responses request
(fn build-body [model context max-tokens options]
  "Build a vanilla OpenAI Responses request body through the shared
   OpenAI-compatible body builder, applying only this adapter's identity and
   encrypted-reasoning include default."
  (compat.build-body
    model context max-tokens (merge-options options)
    {:model model :api API :provider PROVIDER}))

;; @doc fen.extensions.provider_openai.openai_responses.build-request-opts
;; kind: function
;; signature: (build-request-opts model context options on-chunk) -> table
;; summary: Assemble fen.util.http options for a streaming Responses POST.
;; tags: provider openai responses http
(fn build-request-opts [model context options on-chunk]
  "Assemble a fen.util.http opts table for a vanilla OpenAI Responses POST via
   the OpenAI-compatible shared helper."
  (compat.build-request-opts
    model context (merge-options options) on-chunk nil nil
    DEFAULT-BASE-URL RESPONSES-PATH
    {:model model :api API :provider PROVIDER}))

;; @doc fen.extensions.provider_openai.openai_responses.make-stream-pipeline
;; kind: function
;; signature: (make-stream-pipeline model on-event event-mapper) -> state, parser, parser-error
;; summary: Create the SSE parser and shared Responses stream reducer state for one streaming request.
;; tags: provider openai responses streaming
(fn make-stream-pipeline [model on-event event-mapper]
  "Delegate parser/reducer setup to the OpenAI-compatible shared helper."
  (compat.make-stream-pipeline model on-event event-mapper))

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
     :build-request-opts build-request-opts
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
 : merge-options
 : complete}
