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

(local types (require :core.types))
(local json (require :util.json))
(local log (require :util.log))
(local http (require :util.http))
(local sse (require :util.sse))
(local shared (require :providers.openai_responses_shared))

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
    (when max-tokens
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
  (let [headers ["Accept: text/event-stream"
                 "Content-Type: application/json"]]
    (when (and api-key (not= api-key ""))
      (table.insert headers 1 (.. "Authorization: Bearer " api-key)))
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

(fn make-stream-request [model context options on-event event-mapper headers-override url-override]
  "Set up a streaming Responses POST. The Codex provider reuses this by
   passing `event-mapper` (alias `response.done` etc.), `headers-override`,
   and `url-override`. Returns (easy chunks state parser parser-error)."
  (let [opts (or options {})
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (or url-override (build-url base-url))
        max-tokens (or opts.max-tokens 16384)
        body (build-body model context max-tokens opts)
        curl (require :cURL)
        chunks []
        state (shared.new-stream-state model)
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
                               (shared.process-event! state mapped on-event))))))))
        easy (curl.easy)
        headers (or headers-override (request-headers api-key))]
    (configure-easy! easy url body headers opts
                     (fn [chunk]
                       (table.insert chunks chunk)
                       (parser.feed chunk)
                       (length chunk)))
    (values easy chunks state parser parser-error)))

(fn finalize-stream [easy chunks state parser parser-error model on-event ok? err]
  "Shared post-perform handling for both blocking and cooperative paths."
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
        (shared.finalize-stream-state state API PROVIDER on-event))))

(fn complete-stream [model context options on-event yield-fn]
  "Native streaming Responses path. Emits canonical events to `on-event`
   and returns the final AssistantMessage."
  (let [(easy chunks state parser parser-error)
        (make-stream-request model context options on-event nil nil nil)]
    (when on-event (on-event {:type :start}))
    (let [(ok? err) (http.perform-coop easy yield-fn)]
      (finalize-stream easy chunks state parser parser-error model on-event ok? err))))

(fn complete-coop [model context options yield-fn]
  "Cooperative path without an external event sink. Drives the same
   streaming pipeline as `complete-stream` and returns the canonical
   AssistantMessage."
  (let [(easy chunks state parser parser-error)
        (make-stream-request model context options nil nil nil nil)
        (ok? err) (http.perform-coop easy yield-fn)]
    (finalize-stream easy chunks state parser parser-error model nil ok? err)))

(fn complete [model context options]
  "Blocking path used by --print and tests. Streaming under the hood; the
   caller never observes deltas."
  (let [(easy chunks state parser parser-error)
        (make-stream-request model context options nil nil nil nil)
        (ok? err) (pcall #(easy:perform))]
    (finalize-stream easy chunks state parser parser-error model nil ok? err)))

{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : build-body
 : make-stream-request
 : finalize-stream
 : complete
 : complete-coop
 : complete-stream}
