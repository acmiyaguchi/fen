;; Sakana AI provider (api.sakana.ai/v1/responses).
;;
;; Sakana speaks the OpenAI Responses wire protocol, so this adapter reuses
;; the shared OpenAI-compatible reducer/transport in
;; `fen.extensions.provider_openai.openai_responses_shared` (the same module
;; the vanilla and Codex Responses providers build on). This module owns only
;; what is Sakana-specific: the endpoint, the API-key Bearer auth, the
;; canonical provider identity (`:sakana`, not `:openai`), and the reasoning
;; effort mapping Sakana requires.
;;
;; Reasoning effort: Sakana's Fugu models only accept `high` and `xhigh`
;; (`max` is an alias of `xhigh`); any other value is rejected. fen's
;; provider-neutral thinking levels are mapped onto those two values, and
;; `off` (which sends no reasoning-effort at all) leaves reasoning unset so the
;; API uses its own default. This mirrors pi-mono's `pi-sakana-provider`
;; `thinkingLevelMap`.

(local streaming (require :fen.extensions.provider_shared.streaming))
(local compat (require :fen.extensions.provider_openai.openai_responses_shared))

(local API :openai-responses)
(local PROVIDER :sakana)
(local DEFAULT-BASE-URL "https://api.sakana.ai/v1")
(local RESPONSES-PATH "/responses")
;; `reasoning.encrypted_content` lets a reasoning item round-trip across a tool
;; turn on a store:false backend, matching the vanilla Responses provider.
(local DEFAULT-INCLUDE ["reasoning.encrypted_content"])

;; @doc fen.extensions.provider_sakana.sakana_responses.build-url
;; kind: function
;; signature: (build-url base-url) -> string
;; summary: Normalize a Sakana base URL into the /responses endpoint while preserving already-qualified Responses URLs.
;; tags: sakana provider responses http
(fn build-url [base-url]
  (compat.build-url base-url RESPONSES-PATH))

;; @doc fen.extensions.provider_sakana.sakana_responses.clamp-reasoning-effort
;; kind: function
;; signature: (clamp-reasoning-effort effort) -> keyword|nil
;; summary: Map a fen reasoning-effort level onto the only values Sakana accepts (high, xhigh), returning nil to omit reasoning entirely.
;; tags: sakana provider responses reasoning
(fn clamp-reasoning-effort [effort]
  "Sakana rejects every reasoning effort except `high` and `xhigh`. Map
   `xhigh` (and its `max` alias) to `xhigh`; map every other non-nil level up
   to `high`. Returns nil for nil/off so the caller omits reasoning-effort and
   lets Sakana apply its default."
  (if (or (= effort nil) (= effort "") (= effort :off))
      nil
      (or (= effort :xhigh) (= effort :max))
      :xhigh
      :high))

;; @doc fen.extensions.provider_sakana.sakana_responses.request-headers
;; kind: function
;; signature: (request-headers api-key) -> table
;; summary: Build Sakana streaming request headers, adding an Authorization Bearer line only when an API key is present.
;; tags: sakana provider responses http
(fn request-headers [api-key]
  (let [headers {:accept "text/event-stream"
                 :content-type "application/json"}]
    (when (and api-key (not= api-key ""))
      (set headers.authorization (.. "Bearer " api-key)))
    headers))

(fn include-present? [includes value]
  (accumulate [found false _ item (ipairs (or includes [])) &until found]
    (= item value)))

(fn with-default-include [includes]
  "Return a fresh include list containing Sakana's reasoning continuity include.
   Preserve caller-provided entries and never mutate the caller's table."
  (let [out (icollect [_ v (ipairs (or includes []))] v)]
    (when (not (include-present? out (. DEFAULT-INCLUDE 1)))
      (table.insert out (. DEFAULT-INCLUDE 1)))
    out))

;; @doc fen.extensions.provider_sakana.sakana_responses.merge-options
;; kind: function
;; signature: (merge-options opts) -> table
;; summary: Copy per-call options, clamp reasoning-effort to Sakana's accepted values, and ensure the encrypted-reasoning include when reasoning is enabled.
;; tags: sakana provider responses options
(fn merge-options [opts]
  "Return a copy of the per-call options with Sakana's constraints applied,
   without mutating the caller's table. Clamps reasoning-effort to what Sakana
   accepts and ensures `include` carries the encrypted reasoning payload when
   reasoning is enabled so multi-turn reasoning continuity works."
  (let [out {}]
    (each [k v (pairs (or opts {}))] (tset out k v))
    (let [clamped (clamp-reasoning-effort out.reasoning-effort)]
      (if clamped
          (set out.reasoning-effort clamped)
          ;; nil/off: omit reasoning-effort entirely so the shared body builder
          ;; does not send a `reasoning` block Sakana would reject.
          (set out.reasoning-effort nil)))
    (when out.reasoning-effort
      (set out.include (with-default-include out.include)))
    out))

;; @doc fen.extensions.provider_sakana.sakana_responses.complete
;; kind: function
;; signature: (complete model context options ?on-event ?yield-fn) -> AssistantMessage
;; summary: Execute one Sakana Responses call through the shared streaming pipeline with Bearer auth and Sakana reasoning-effort clamping.
;; tags: sakana provider responses complete
(fn complete [model context options ?on-event ?yield-fn]
  "Single entry. Always streams under the hood; blocking when no yield-fn is
   given (print mode / tests), cooperative otherwise. `?on-event` is plumbed
   through for callers that want stream deltas; passing nil yields just the
   final AssistantMessage."
  (let [opts (merge-options options)
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (build-url base-url)
        headers (request-headers api-key)]
    (streaming.complete-streaming
      {:provider PROVIDER
       :model model
       :context context
       :options opts
       :on-event ?on-event
       :yield-fn ?yield-fn
       :make-stream-pipeline (fn [model on-event]
                               (compat.make-stream-pipeline model on-event nil))
       :build-request-opts (fn [model context opts on-chunk]
                             (compat.build-request-opts
                               model context opts on-chunk headers url
                               DEFAULT-BASE-URL RESPONSES-PATH
                               {:model model :api API :provider PROVIDER}))
       :finalize-stream (fn [state parser parser-error model resp on-event request-opts]
                          (compat.finalize-stream
                            state parser parser-error API PROVIDER model resp on-event
                            request-opts))})))

;; @doc fen.extensions.provider_sakana.sakana_responses.api
;; kind: data
;; signature: keyword
;; summary: Provider API family keyword (openai-responses) used by registry metadata for the Sakana adapter.
;; tags: sakana provider responses metadata
;; @doc fen.extensions.provider_sakana.sakana_responses.provider
;; kind: data
;; signature: keyword
;; summary: Provider owner keyword used on canonical assistant messages emitted by the Sakana adapter.
;; tags: sakana provider responses metadata
;; @doc fen.extensions.provider_sakana.sakana_responses.default-base-url
;; kind: data
;; signature: string
;; summary: Default Sakana API root used before appending /responses.
;; tags: sakana provider responses metadata
{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : clamp-reasoning-effort
 : request-headers
 : merge-options
 : complete}
