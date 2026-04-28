;; ChatGPT Plus/Pro Codex subscription provider.
;;
;; Talks to chatgpt.com/backend-api/codex/responses with an OAuth access
;; token from ~/.pi/agent/auth.json. The wire shape is OpenAI Responses
;; with two Codex aliases the reducer doesn't natively understand
;; (`response.done`, `response.incomplete` → `response.completed`),
;; handled by `map-codex-event`.
;;
;; Auth: pi-mono runs the PKCE login flow; we read the credentials it
;; persisted, refresh tokens ourselves when they expire, and write back
;; atomically. The user runs `pi login openai-codex` once; everything
;; after that is invisible.

(local types (require :core.types))
(local json (require :util.json))
(local log (require :util.log))
(local http (require :util.http))
(local responses (require :providers.openai_responses))
(local codex-auth (require :auth.openai_codex))

(local API :openai-codex-responses)
(local PROVIDER :openai-codex)
(local DEFAULT-BASE-URL "https://chatgpt.com/backend-api")
(local CODEX-PATH "/codex/responses")
;; `reasoning.encrypted_content` is what the server uses to round-trip
;; reasoning state between turns; without it multi-turn reasoning
;; continuity degrades.
(local DEFAULT-INCLUDE ["reasoning.encrypted_content"])

(fn ends-with? [s suffix]
  (let [n (length suffix)]
    (and (>= (length s) n)
         (= (string.sub s (- (length s) n -1)) suffix))))

(fn build-url [base-url]
  (if (ends-with? base-url CODEX-PATH)
      base-url
      (.. base-url CODEX-PATH)))

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

(fn build-headers [creds]
  ["Accept: text/event-stream"
   "Content-Type: application/json"
   (.. "Authorization: Bearer " creds.access)
   (.. "chatgpt-account-id: " creds.accountId)
   "originator: pi"
   "OpenAI-Beta: responses=experimental"
   (.. "User-Agent: " USER-AGENT)])

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

(fn run-stream [model context options on-event yield-fn blocking?]
  "Shared body for complete-stream / complete-coop / complete. `blocking?`
   selects the curl driver: `easy:perform` for true, `http.perform-coop`
   for false."
  (let [opts (merge-options options)
        creds (resolve-creds opts)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (build-url base-url)
        headers (build-headers creds)
        (easy chunks state parser parser-error)
        (responses.make-stream-request
          model context opts on-event map-codex-event headers url)]
    (when on-event (on-event {:type :start}))
    (let [(ok? err) (if blocking?
                        (pcall #(easy:perform))
                        (http.perform-coop easy yield-fn))]
      (responses.finalize-stream
        easy chunks state parser parser-error model on-event ok? err))))

(fn complete-stream [model context options on-event yield-fn]
  (run-stream model context options on-event yield-fn false))

(fn complete-coop [model context options yield-fn]
  (run-stream model context options nil yield-fn false))

(fn complete [model context options]
  (run-stream model context options nil nil true))

{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : map-codex-event
 : build-headers
 : merge-options
 : complete
 : complete-coop
 : complete-stream}
