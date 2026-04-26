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

(local API :openai-completions)
(local PROVIDER :openai)
(local DEFAULT-BASE-URL "https://api.openai.com/v1/chat/completions")

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
        ;; OpenAI requires content OR tool_calls; content can be empty string
        ;; when only tool_calls are present.
        (set out.content (if (= text "") json.null text))
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

(fn decode-tool-arguments [args-str]
  "OpenAI tool_calls.function.arguments is a JSON-encoded string. Decode to a
   canonical Lua table; on parse failure, return the empty table and log."
  (if (or (= args-str nil) (= args-str ""))
      {}
      (let [(ok? value) (pcall json.decode args-str)]
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

(fn build-body [model context max-tokens]
  (let [body {: model
              :max_tokens (or max-tokens 1024)
              :messages (convert-messages context.messages context.system-prompt)}]
    (when (and context.tools (> (length context.tools) 0))
      (set body.tools (convert-tools context.tools))
      (set body.tool_choice :auto))
    body))

(fn complete [model context options]
  "Non-streaming POST. Returns a canonical AssistantMessage; on transport or
   HTTP failure the message has stop-reason :error with error-message set."
  (let [api-key (or options.api-key options.api_key)
        base-url (or options.base-url DEFAULT-BASE-URL)
        max-tokens (or options.max-tokens 1024)
        body (build-body model context max-tokens)
        curl (require :cURL)
        chunks []
        easy (curl.easy)]
    (easy:setopt_url base-url)
    (easy:setopt_post 1)
    (easy:setopt_postfields (json.encode body))
    (easy:setopt_httpheader [(.. "Authorization: Bearer " (or api-key ""))
                             "Content-Type: application/json"])
    (easy:setopt_writefunction
      (fn [chunk] (table.insert chunks chunk) (length chunk)))
    (let [(ok? perr) (pcall #(easy:perform))
          status (easy:getinfo_response_code)]
      (easy:close)
      (if (not ok?)
          (do (log.error (.. "curl perform failed: " (tostring perr)))
              (types.assistant-error API PROVIDER model perr))
          (let [raw (table.concat chunks)
                (decoded? value) (pcall json.decode raw)]
            (if (not decoded?)
                (do (log.error (.. "json decode failed: " (tostring value) " body=" raw))
                    (types.assistant-error API PROVIDER model value))
                (if (or (< status 200) (>= status 300))
                    (do (log.error (.. "http " status ": " raw))
                        (types.assistant-error API PROVIDER model
                          (.. "HTTP " status ": " raw)))
                    (parse-response value model))))))))

{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 : convert-messages
 : convert-tools
 : map-stop-reason
 : parse-response
 : build-body
 : complete}
