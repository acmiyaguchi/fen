;; Canonical message and tool types — the agent-side shapes that providers
;; convert to/from on the way to the wire.
;;
;; Mirrors pi-mono's canonical types (packages/ai/src/types.ts,
;; packages/agent/src/types.ts). Field names are kebab-case (Fennel idiom);
;; semantics are identical. Wire shapes (snake_case JSON) are produced by
;; provider modules in src/providers/.
;;
;; Skipped vs pi-mono (no consumer in agent-fennel today; additive later):
;;   - ImageContent
;;   - response-id / textSignature / thoughtSignature fields for some session
;;     continuity flows (we keep `thinking-signature` because reasoning models
;;     require it for multi-turn).
;;   - usage.cost (no model registry / pricing)
;;   - executionMode / signal / onUpdate on tools (sequential, no abort)
;;   - prepareArguments / TypeBox schema validation
;;
;; ============================================================
;; Content blocks (entries in AssistantMessage.content / etc.)
;; ============================================================
;;
;; TextContent       {:type :text :text "..."}
;; ThinkingContent   {:type :thinking
;;                    :thinking "..."
;;                    :thinking-signature? "opaque"   ; required for multi-turn echo
;;                                                    ; (Anthropic extended thinking,
;;                                                    ; OpenAI Responses reasoning items)
;;                    :redacted? false}                ; true when safety filters
;;                                                    ; redacted the visible text
;; ToolCall          {:type :tool-call :id "call_1" :name "bash"
;;                    :arguments {:cmd "echo hi"}}   ; arguments is a parsed table, not a JSON string
;;
;; ============================================================
;; Messages (entries in AgentContext.messages)
;; ============================================================
;;
;; UserMessage
;;   {:role :user
;;    :content "..."                            ; or [TextContent]
;;    :timestamp <ms>}
;;
;; AssistantMessage
;;   {:role :assistant
;;    :content [TextContent | ToolCall ...]      ; always an array
;;    :api :openai-completions | :anthropic-messages
;;    :provider :openai | :anthropic
;;    :model "gpt-4o-mini"
;;    :usage Usage
;;    :stop-reason StopReason
;;    :error-message? "..."                      ; only when stop-reason = :error
;;    :timestamp <ms>}
;;
;; ToolResultMessage
;;   {:role :tool-result
;;    :tool-call-id "call_1"
;;    :tool-name "bash"
;;    :content [TextContent]                     ; always an array
;;    :is-error? false
;;    :timestamp <ms>}
;;
;; ============================================================
;; Enums and small records
;; ============================================================
;;
;; StopReason  :stop | :length | :tool-use | :error | :aborted
;;
;; Usage  {:input N :output N :cache-read N :cache-write N :total-tokens N}
;;
;; ============================================================
;; Tool spec (canonical, provider-agnostic)
;; ============================================================
;;
;; Tool
;;   {:name "bash"
;;    :description "Run a shell command…"
;;    :parameters {:type :object :properties {...} :required [...]}}
;;
;; AgentTool extends Tool with:
;;   {:label "Bash"            ; UI label
;;    :execute (fn [params] → AgentToolResult)}
;;
;; AgentToolResult
;;   {:content [TextContent ...]
;;    :details? <anything>      ; opaque, for richer UI
;;    :is-error? false}
;;
;; ============================================================
;; Context passed to a provider
;; ============================================================
;;
;; AgentContext
;;   {:system-prompt "..."          ; nil if absent
;;    :messages [Message ...]       ; UserMessage | AssistantMessage | ToolResultMessage
;;    :tools [Tool ...]             ; canonical Tool list (no provider wrapping)
;;    :max-tokens 1024}             ; per-call cap
;;
;; ============================================================
;; Constructors (small helpers; preferring functions over magic strings)
;; ============================================================

(fn now-ms [] (* (os.time) 1000))

(fn text-block [s] {:type :text :text s})

(fn thinking-block [{: thinking : thinking-signature : redacted}]
  (let [b {:type :thinking :thinking (or thinking "")}]
    (when thinking-signature (set b.thinking-signature thinking-signature))
    (when redacted (set b.redacted? true))
    b))

(fn tool-call-block [id name args]
  {:type :tool-call : id : name :arguments args})

(fn user-message [content]
  {:role :user
   :content content
   :timestamp (now-ms)})

(fn assistant-message [{: content : api : provider : model : usage : stop-reason : error-message}]
  (let [m {:role :assistant
           :content (or content [])
           : api
           : provider
           : model
           :usage (or usage {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0})
           :stop-reason (or stop-reason :stop)
           :timestamp (now-ms)}]
    (when error-message (set m.error-message error-message))
    m))

(fn tool-result-message [{: tool-call-id : tool-name : content : details : is-error?}]
  (let [m {:role :tool-result
           : tool-call-id
           : tool-name
           :content (or content [])
           :is-error? (or is-error? false)
           :timestamp (now-ms)}]
    (when (not= details nil) (set m.details details))
    m))

(fn assistant-error [api provider model error-message]
  "Convenience: build an AssistantMessage representing a transport/HTTP failure."
  (assistant-message
    {: api : provider : model
     :content [(text-block (.. "[error] " (tostring error-message)))]
     :stop-reason :error
     : error-message}))

;; Extract the visible text from an assistant message (concat all TextContent).
(fn assistant-text [msg]
  (let [parts []]
    (each [_ block (ipairs (or msg.content []))]
      (when (= block.type :text)
        (table.insert parts (or block.text ""))))
    (table.concat parts "")))

(fn filter-blocks [msg block-type]
  "Return content blocks of `msg` matching `block-type`, in order."
  (let [out []]
    (each [_ block (ipairs (or msg.content []))]
      (when (= block.type block-type)
        (table.insert out block)))
    out))

(fn assistant-tool-calls [msg] (filter-blocks msg :tool-call))
(fn assistant-thinking [msg] (filter-blocks msg :thinking))

{: now-ms
 : text-block
 : thinking-block
 : tool-call-block
 : user-message
 : assistant-message
 : tool-result-message
 : assistant-error
 : assistant-text
 : assistant-tool-calls
 : assistant-thinking}
