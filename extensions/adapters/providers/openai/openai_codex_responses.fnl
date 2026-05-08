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

(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local http (require :fen.util.http))
(local compat (require :fen.extensions.provider_openai.openai_responses_shared))
(local codex-auth (require :fen.extensions.provider_openai.openai_codex_oauth))

(local API :openai-codex-responses)
(local PROVIDER :openai-codex)
(local DEFAULT-BASE-URL "https://chatgpt.com/backend-api")
(local CODEX-PATH "/codex/responses")
;; `reasoning.encrypted_content` is what the server uses to round-trip
;; reasoning state between turns; without it multi-turn reasoning
;; continuity degrades.
(local DEFAULT-INCLUDE ["reasoning.encrypted_content"])

;; @doc fen.extensions.provider_openai.openai_codex_responses.build-url
;; kind: function
;; signature: (build-url base-url) -> string
;; summary: Normalize a ChatGPT backend base URL into the Codex Responses endpoint while preserving fully-qualified Codex URLs.
;; tags: codex provider responses http
(fn build-url [base-url]
  (compat.build-url base-url CODEX-PATH))

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

(fn resolve-creds [opts]
  "Use credentials passed in via `provider-options.creds` when present
   (main.fnl resolves them once at startup), else fall back to a fresh
   read of auth.json so /reload picks up rotated tokens."
  (or opts.creds (codex-auth.get-fresh-creds!)))

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
        headers (build-headers creds)
        (state parser parser-error)
        (compat.make-stream-pipeline model ?on-event map-codex-event)
        req-opts (compat.build-request-opts
                   model context opts
                   (fn [chunk] (parser.feed chunk))
                   headers url DEFAULT-BASE-URL CODEX-PATH)]
    (set req-opts.yield ?yield-fn)
    (when ?on-event (?on-event {:type :start}))
    (let [resp (http.request req-opts)]
      (compat.finalize-stream
        state parser parser-error API PROVIDER model resp ?on-event))))

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
 : map-codex-event
 : build-headers
 : merge-options
 : complete}
