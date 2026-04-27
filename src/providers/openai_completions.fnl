;; OpenAI Chat Completions provider.
;;
;; Mirrors pi-mono's `packages/ai/src/providers/openai-completions.ts`
;; surface: convert-messages, convert-tools, map-stop-reason, parse-response,
;; complete (non-streaming POST). The agent loop sees only canonical
;; `core.types` shapes; everything OpenAI-specific lives here.
;;
;; Note: Chat Completions does not return thinking content even for the
;; reasoning model family. The o-series / GPT-5 reasoning text is only
;; surfaced via the `openai-responses` API. When that provider lands it'll
;; live alongside this file as `providers/openai_responses.fnl`.

(local types (require :core.types))
(local json (require :util.json))
(local log (require :util.log))
(local http (require :util.http))

(local API :openai-completions)
(local PROVIDER :openai)
(local DEFAULT-BASE-URL "https://api.openai.com/v1")
(local CHAT-COMPLETIONS-PATH "/chat/completions")

(fn ends-with? [s suffix]
  (let [n (length suffix)]
    (and (>= (length s) n)
         (= (string.sub s (- (length s) n -1)) suffix))))

(fn build-url [base-url]
  "Mirror pi-mono's models.json convention: `baseUrl` is the v1 root
   (`http://localhost:11434/v1`); we append `/chat/completions`. If the
   caller passed a fully-qualified completions URL (legacy), respect it."
  (if (ends-with? base-url CHAT-COMPLETIONS-PATH)
      base-url
      (.. base-url CHAT-COMPLETIONS-PATH)))

;; ----------------------------------------------------------------
;; Outbound: canonical → OpenAI wire
;; ----------------------------------------------------------------

(fn text-of-content [content]
  "Concat all text blocks of an assistant/tool-result content array.
   Drops non-text blocks (thinking content, etc) — Chat Completions
   doesn't accept them back."
  (if (= (type content) :string)
      content
      (let [parts []]
        (each [_ block (ipairs (or content []))]
          (when (= block.type :text)
            (table.insert parts (or block.text ""))))
        (table.concat parts ""))))

(fn extract-tool-calls [content]
  "Collect ToolCall blocks from an assistant content array, in OpenAI shape."
  (let [out []]
    (each [_ block (ipairs (or content []))]
      (when (= block.type :tool-call)
        (table.insert out
                      {:id block.id
                       :type :function
                       :function {:name block.name
                                  :arguments (json.encode (or block.arguments {}))}})))
    out))

(fn convert-message [m]
  (if (= m.role :user)
      {:role :user :content (text-of-content m.content)}

      (= m.role :assistant)
      (let [text (text-of-content m.content)
            tool-calls (extract-tool-calls m.content)
            out {:role :assistant}]
        ;; OpenAI requires content OR tool_calls. Null content is only valid
        ;; when tool_calls is present; otherwise send empty string.
        (set out.content
             (if (and (= text "") (> (length tool-calls) 0)) json.null text))
        (when (> (length tool-calls) 0)
          (set out.tool_calls tool-calls))
        out)

      (= m.role :tool-result)
      {:role :tool
       :tool_call_id m.tool-call-id
       :content (text-of-content m.content)}

      (error (.. "openai_completions: unhandled message role: " (tostring m.role)))))

(fn convert-messages [messages system-prompt]
  "Canonical Messages + optional system prompt → OpenAI ChatCompletionMessageParam[]."
  (let [out []]
    (when (and system-prompt (not= system-prompt ""))
      (table.insert out {:role :system :content system-prompt}))
    (each [_ m (ipairs (or messages []))]
      (table.insert out (convert-message m)))
    out))

(fn convert-tools [tools]
  "Canonical Tool[] → OpenAI tool-function[]."
  (let [out []]
    (each [_ t (ipairs (or tools []))]
      (table.insert out
                    {:type :function
                     :function {:name t.name
                                :description t.description
                                :parameters t.parameters}}))
    out))

;; ----------------------------------------------------------------
;; Inbound: OpenAI wire → canonical
;; ----------------------------------------------------------------

(fn map-stop-reason [reason]
  "OpenAI finish_reason → canonical StopReason. Mirrors pi-mono
   openai-completions.ts:989-1012."
  (if (or (= reason nil) (= reason :stop) (= reason :end))
      (values :stop nil)
      (= reason :length)
      (values :length nil)
      (or (= reason :tool_calls) (= reason :function_call))
      (values :tool-use nil)
      (= reason :content_filter)
      (values :error "Provider finish_reason: content_filter")
      (= reason :network_error)
      (values :error "Provider finish_reason: network_error")
      ;; default
      (values :error (.. "Provider finish_reason: " (tostring reason)))))

(fn decode-tool-arguments [args]
  "OpenAI tool_calls.function.arguments is a JSON-encoded string per spec, but
   some OpenAI-compatible servers (notably some Ollama versions) return a
   parsed object instead. Accept either; on parse failure of a string, return
   the empty table and log."
  (if (or (= args nil) (= args ""))
      {}
      (= (type args) :table)
      args
      (let [(ok? value) (pcall json.decode args)]
        (if ok? value
            (do (log.warn (.. "openai_completions: bad tool args JSON: "
                              (tostring value)))
                {})))))

(fn parse-response [resp model]
  "OpenAI response → canonical AssistantMessage."
  (let [choice (?. resp :choices 1)
        msg (?. choice :message)
        finish (?. choice :finish_reason)
        (stop-reason error-message) (map-stop-reason finish)
        usage (or resp.usage {})
        content []]
    ;; OpenAI returns `content: null` (cjson.null lightuserdata) when the
    ;; model only emits tool_calls. Guard on `string` so a userdata sentinel
    ;; never sneaks into a text-block — it would crash table.concat on the
    ;; next turn through text-of-content.
    (when (and msg (= (type msg.content) :string) (not= msg.content ""))
      (table.insert content (types.text-block msg.content)))
    (when (and msg msg.tool_calls)
      (each [_ tc (ipairs msg.tool_calls)]
        (table.insert content
                      (types.tool-call-block
                        tc.id
                        (?. tc :function :name)
                        (decode-tool-arguments (?. tc :function :arguments))))))
    (types.assistant-message
      {:api API :provider PROVIDER : model
       : content
       :usage {:input (or usage.prompt_tokens 0)
               :output (or usage.completion_tokens 0)
               :cache-read (or (?. usage :prompt_tokens_details :cached_tokens) 0)
               :cache-write 0
               :total-tokens (or usage.total_tokens 0)}
       : stop-reason
       : error-message})))

;; ----------------------------------------------------------------
;; HTTP transport
;; ----------------------------------------------------------------

(fn build-body [model context max-tokens compat]
  "Build the chat-completions request body. `compat` is an optional table of
   per-provider OpenAI-compat overrides (see `core.models`). Today only
   `:maxTokensField` is honored — pass `\"max_tokens\"` for Ollama / older
   servers that reject `max_completion_tokens`."
  (let [max-field (or (?. compat :maxTokensField) :max_completion_tokens)
        body {: model
              :messages (convert-messages context.messages context.system-prompt)}]
    (tset body max-field (or max-tokens 16384))
    (when (and context.tools (> (length context.tools) 0))
      (set body.tools (convert-tools context.tools))
      (set body.tool_choice :auto))
    body))

(fn make-request [model context options]
  (let [opts (or options {})
        api-key (or opts.api-key opts.api_key)
        base-url (or opts.base-url DEFAULT-BASE-URL)
        url (build-url base-url)
        max-tokens (or opts.max-tokens 16384)
        compat opts.compat
        body (build-body model context max-tokens compat)
        curl (require :cURL)
        chunks []
        easy (curl.easy)
        ;; Skip the Authorization header entirely when there's no key.
        ;; Ollama and other auth-less local servers ignore Bearer tokens but
        ;; sending an empty `Authorization: Bearer ` is at best noise and at
        ;; worst makes some servers reject the request.
        headers ["Content-Type: application/json"]]
    (when (and api-key (not= api-key ""))
      (table.insert headers 1 (.. "Authorization: Bearer " api-key)))
    (easy:setopt_url url)
    (easy:setopt_post 1)
    (easy:setopt_postfields (json.encode body))
    (easy:setopt_httpheader headers)
    (easy:setopt_writefunction
      (fn [chunk] (table.insert chunks chunk) (length chunk)))
    (values easy chunks)))

(fn response->assistant [model chunks status ok? err]
  (if (not ok?)
      (do (log.error (.. "curl perform failed: " (tostring err)))
          (types.assistant-error API PROVIDER model err))
      (let [raw (table.concat chunks)
            (decoded? value) (pcall json.decode raw)]
        (if (not decoded?)
            (do (log.error (.. "json decode failed: " (tostring value) " body=" raw))
                (types.assistant-error API PROVIDER model value))
            (if (or (< status 200) (>= status 300))
                (do (log.error (.. "http " status ": " raw))
                    (types.assistant-error API PROVIDER model
                      (.. "HTTP " status ": " raw)))
                (parse-response value model))))))

(fn complete [model context options]
  "Non-streaming POST. Returns a canonical AssistantMessage; on transport or
   HTTP failure the message has stop-reason :error with error-message set."
  (let [(easy chunks) (make-request model context options)
        (ok? err) (pcall #(easy:perform))
        status (easy:getinfo_response_code)]
    (easy:close)
    (response->assistant model chunks status ok? err)))

(fn complete-coop [model context options yield-fn]
  "Cooperative non-streaming POST for interactive mode. Drives the easy handle
   through curl multi one short step per coroutine resume and calls `yield-fn`
   between steps so the TUI can keep processing input/redraws while the
   provider request is in flight."
  (let [(easy chunks) (make-request model context options)
        (ok? err) (http.perform-coop easy yield-fn)
        status (easy:getinfo_response_code)]
    (easy:close)
    (response->assistant model chunks status ok? err)))

{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : build-url
 : convert-messages
 : convert-tools
 : map-stop-reason
 : parse-response
 : build-body
 : complete
 : complete-coop}
