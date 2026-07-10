;; ChatGPT Plus/Pro Codex subscription provider.
;;
;; Talks to chatgpt.com/backend-api/codex/responses with an OAuth access
;; token from fen's writable auth.json, falling back to pi-mono's auth.json
;; read-only. The wire shape is OpenAI Responses with two Codex aliases
;; the reducer doesn't natively understand (`response.done`,
;; `response.incomplete` → `response.completed`), handled by
;; `map-codex-event`.
;;
;; Auth: fen has its own PKCE login flow and can also read credentials
;; pi-mono persisted. Refreshes write only to fen's writable auth path.

(local streaming (require :fen.extensions.provider_shared.streaming))
(local compat (require :fen.extensions.provider_openai.openai_responses_shared))
(local codex-auth (require :fen.extensions.provider_openai.openai_codex_oauth))
(local json (require :fen.util.json))
(local http (require :fen.util.http))

(local API :openai-codex-responses)
(local PROVIDER :openai-codex)
(local DEFAULT-BASE-URL "https://chatgpt.com/backend-api")
(local CODEX-PATH "/codex/responses")
(local CODEX-MODELS-PATH "/codex/models")
(local CODEX-CLIENT-VERSION "0.124.0")
;; `reasoning.encrypted_content` is what the server uses to round-trip
;; reasoning state between turns; without it multi-turn reasoning
;; continuity degrades.
(local DEFAULT-INCLUDE ["reasoning.encrypted_content"])
;; The authenticated Codex catalog can lag rollout / omit published models.
;; Keep a small Pi-aligned allowlist for known Codex model IDs so model
;; resolution can select them before the catalog catches up. Dynamic catalog
;; entries win on duplicate IDs.
(local PINNED-CODEX-MODELS
  [{:id "gpt-5.6-luna"
    :name "GPT-5.6 Luna"
    :context-window 372000
    :default-reasoning-level :medium}
   {:id "gpt-5.6-sol"
    :name "GPT-5.6 Sol"
    :context-window 372000
    :default-reasoning-level :medium}
   {:id "gpt-5.6-terra"
    :name "GPT-5.6 Terra"
    :context-window 372000
    :default-reasoning-level :medium}])

;; @doc fen.extensions.provider_openai.openai_codex_responses.build-url
;; kind: function
;; signature: (build-url base-url) -> string
;; summary: Normalize a ChatGPT backend base URL into the Codex Responses endpoint while preserving fully-qualified Codex URLs.
;; tags: codex provider responses http
(fn build-url [base-url]
  (compat.build-url base-url CODEX-PATH))

;; @doc fen.extensions.provider_openai.openai_codex_responses.build-models-url
;; kind: function
;; signature: (build-models-url base-url ?client-version) -> string
;; summary: Normalize a ChatGPT backend base URL into the Codex model catalog endpoint.
;; tags: codex provider models http
(fn ends-with? [s suffix]
  (let [n (length suffix)]
    (and (>= (length s) n)
         (= (string.sub s (- (length s) n -1)) suffix))))

(fn replace-suffix [s old new]
  (if (ends-with? s old)
      (.. (string.sub s 1 (- (length s) (length old))) new)
      s))

(fn build-models-url [base-url ?client-version]
  (let [catalog-base (replace-suffix base-url CODEX-PATH CODEX-MODELS-PATH)
        root (compat.build-url catalog-base CODEX-MODELS-PATH)
        sep (if (string.find root "?" 1 true) "&" "?")]
    (.. root sep "client_version=" (or ?client-version CODEX-CLIENT-VERSION))))

(fn detect-user-agent []
  "Best-effort `pi (linux ${release}; ${arch})`. Falls back to `pi (lua)`
   if uname is missing or fails."
  (let [pipe (io.popen "uname -s -r -m 2>/dev/null")
        line (and pipe (pipe:read "*l"))]
    (when pipe (pipe:close))
    (if (and line (not= line ""))
        (.. "pi (" line ")")
        "pi (lua)")))

(local USER-AGENT (detect-user-agent))

;; @doc fen.extensions.provider_openai.openai_codex_responses.build-headers
;; kind: function
;; signature: (build-headers creds) -> table
;; summary: Build ChatGPT Codex streaming request headers from OAuth credentials, including account id, beta flag, and user agent.
;; tags: codex provider responses http
(fn build-headers [creds]
  {:accept "text/event-stream"
   :content-type "application/json"
   :authorization (.. "Bearer " creds.access)
   :chatgpt-account-id creds.accountId
   :originator "pi"
   :openai-beta "responses=experimental"
   :user-agent USER-AGENT})

;; @doc fen.extensions.provider_openai.openai_codex_responses.map-codex-event
;; kind: function
;; signature: (map-codex-event ev) -> table
;; summary: Normalize Codex response.done and response.incomplete SSE aliases into the shared Responses reducer's response.completed event.
;; tags: codex provider responses streaming
(fn map-codex-event [ev]
  "Codex emits `response.done` and `response.incomplete` aliases for
   `response.completed`. Pass everything else through unchanged."
  (case (?. ev :type)
    :response.done
    (let [out {}]
      (each [k v (pairs ev)] (tset out k v))
      (set out.type :response.completed)
      out)

    :response.incomplete
    (let [out {}]
      (each [k v (pairs ev)] (tset out k v))
      (set out.type :response.completed)
      out)

    _ ev))

;; @doc fen.extensions.provider_openai.openai_codex_responses.merge-options
;; kind: function
;; signature: (merge-options opts) -> table
;; summary: Copy provider options and add Codex defaults for encrypted reasoning includes and skipping unsupported max_output_tokens.
;; tags: codex provider responses options
(fn merge-options [opts]
  "Set Codex-specific defaults onto the per-call options table without
   mutating the caller's table."
  (let [out {}]
    (each [k v (pairs (or opts {}))] (tset out k v))
    (when (or (not out.include) (= (length out.include) 0))
      (set out.include DEFAULT-INCLUDE))
    ;; Codex rejects max_output_tokens; the vanilla Responses provider
    ;; honors this flag and skips that body field.
    (set out.skip-max-output-tokens? true)
    out))

(fn selectable-codex-model? [m]
  (and (= (type m) :table)
       (= (or m.visibility :list) :list)
       (not= m.supported_in_api false)))

;; @doc fen.extensions.provider_openai.openai_codex_responses.parse-models
;; kind: function
;; signature: (parse-models decoded) -> [{:id string}]
;; summary: Extract selectable Codex model ids from the ChatGPT backend catalog.
;; tags: codex provider models parse
(fn parse-models [decoded]
  "Keep only list-visible models supported by the Codex Responses API. Hidden
   helpers like codex-auto-review and list-visible non-API models are omitted."
  (let [out []]
    (each [_ m (ipairs (or (?. decoded :models) []))]
      (when (selectable-codex-model? m)
        (let [id (or m.slug m.id)]
          (when (and id (not= id ""))
            (table.insert out {:id id
                               :name m.display_name
                               :context-window m.context_window
                               :default-reasoning-level m.default_reasoning_level})))))
    out))

(fn append-pinned-models [models catalog-models]
  "Append known Codex models absent from the authenticated catalog.
   An explicit hidden or unsupported catalog entry remains excluded."
  (let [seen {}]
    ;; Mark every raw catalog ID, not merely selectable entries: an explicit
    ;; server exclusion takes precedence over the pinned compatibility list.
    (each [_ m (ipairs (or catalog-models []))]
      (let [id (or m.slug m.id)]
        (when id (tset seen id true))))
    (each [_ m (ipairs (or models []))]
      (when m.id (tset seen m.id true)))
    (each [_ m (ipairs PINNED-CODEX-MODELS)]
      (when (not (. seen m.id))
        (table.insert models m)
        (tset seen m.id true)))
    models))

(fn resolve-creds [opts]
  "Use credentials passed in via `provider-options.creds` when present
   (main.fnl resolves them once at startup), else fall back to a fresh
   read of auth.json so /reload picks up rotated tokens."
  (or opts.creds (codex-auth.get-fresh-creds!)))

;; @doc fen.extensions.provider_openai.openai_codex_responses.list-models
;; kind: function
;; signature: (list-models opts) -> [{:id string}]
;; summary: Fetch the authenticated ChatGPT/Codex model catalog.
;; tags: codex provider models http
(fn list-models [opts]
  (let [opts (or opts {})
        creds (resolve-creds opts)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        resp (http.request {:method :GET
                            :url (build-models-url base-url opts.client-version)
                            :headers (build-headers creds)
                            :timeout-ms (or opts.timeout-ms 30000)
                            :connect-timeout-ms (or opts.connect-timeout-ms 10000)
                            :yield opts.yield})]
    (when resp.error
      (error resp.error))
    (when (or (< resp.status 200) (>= resp.status 300))
      (error (.. "HTTP " resp.status ": " (or resp.body ""))))
    (let [(ok? decoded) (pcall json.decode (or resp.body ""))]
      (when (not ok?)
        (error (.. "invalid model catalog JSON: " (tostring decoded))))
      (append-pinned-models (parse-models decoded) decoded.models))))

;; @doc fen.extensions.provider_openai.openai_codex_responses.complete
;; kind: function
;; signature: (complete model context options ?on-event ?yield-fn) -> AssistantMessage
;; summary: Execute one ChatGPT Codex Responses call through the shared streaming pipeline with OAuth credentials and Codex event mapping.
;; tags: codex provider responses complete
(fn complete [model context options ?on-event ?yield-fn]
  "Single entry. Drives the same Codex SSE pipeline regardless of caller —
   blocking when no yield-fn is given (print mode / tests), cooperative
   otherwise. `?on-event` is plumbed through for callers that want stream
   deltas; passing nil yields just the final AssistantMessage."
  (let [opts (merge-options options)
        creds (resolve-creds opts)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (build-url base-url)
        headers (build-headers creds)]
    (streaming.complete-streaming
      {:provider PROVIDER
       :model model
       :context context
       :options opts
       :on-event ?on-event
       :yield-fn ?yield-fn
       :make-stream-pipeline (fn [model on-event]
                               (compat.make-stream-pipeline model on-event map-codex-event))
       :build-request-opts (fn [model context opts on-chunk]
                             (compat.build-request-opts
                               model context opts on-chunk headers url
                               DEFAULT-BASE-URL CODEX-PATH
                               {:model model :api API :provider PROVIDER}))
       :finalize-stream (fn [state parser parser-error model resp on-event request-opts]
                          (compat.finalize-stream
                            state parser parser-error API PROVIDER model resp on-event
                            request-opts))})))

;; @doc fen.extensions.provider_openai.openai_codex_responses.api
;; kind: data
;; signature: keyword
;; summary: Provider API family keyword used by registry metadata for the ChatGPT Codex Responses adapter.
;; tags: codex provider responses metadata
;; @doc fen.extensions.provider_openai.openai_codex_responses.provider
;; kind: data
;; signature: keyword
;; summary: Provider owner keyword used on canonical assistant messages emitted by the Codex adapter.
;; tags: codex provider responses metadata
;; @doc fen.extensions.provider_openai.openai_codex_responses.default-base-url
;; kind: data
;; signature: string
;; summary: Default ChatGPT backend API root used by the Codex Responses adapter before appending /codex/responses.
;; tags: codex provider responses metadata
{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : build-models-url
 : map-codex-event
 : build-headers
 : merge-options
 : parse-models
 :append-pinned-models append-pinned-models
 :pinned-models PINNED-CODEX-MODELS
 : list-models
 : complete}
