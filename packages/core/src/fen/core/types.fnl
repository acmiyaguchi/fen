;; Canonical provider-agnostic message/tool types; wire shapes (snake_case JSON) live in provider modules.

;; @doc fen.core.types.now-ms
;; kind: function
;; signature: (now-ms) -> number
;; summary: Current epoch in milliseconds. Used as the :timestamp field on canonical messages.
;; tags: types time
(fn now-ms [] (* (os.time) 1000))

;; @doc fen.core.types.text-block
;; kind: function
;; signature: (text-block s) -> TextContent
;; summary: Build a {:type :text :text s} block. The visible-text content kind.
;; tags: types content-block
;; see-also: type:TextContent
(fn text-block [s] {:type :text :text s})

;; @doc fen.core.types.thinking-block
;; kind: function
;; signature: (thinking-block {: thinking : thinking-signature : redacted}) -> ThinkingContent
;; summary: Build a {:type :thinking ...} block. Carries reasoning text plus the opaque echo signature required by Anthropic extended thinking and OpenAI Responses for multi-turn echo.
;; tags: types content-block thinking
;; see-also: type:ThinkingContent
(fn thinking-block [{: thinking : thinking-signature : redacted}]
  (let [b {:type :thinking :thinking (or thinking "")}]
    (when thinking-signature (set b.thinking-signature thinking-signature))
    (when redacted (set b.redacted? true))
    b))

;; @doc fen.core.types.tool-call-block
;; kind: function
;; signature: (tool-call-block id name args) -> ToolCall
;; summary: Build a {:type :tool-call :id :name :arguments} block. Arguments is a parsed Lua table — providers JSON-decode wire arguments before calling this.
;; tags: types content-block tool-call
;; see-also: type:ToolCall
(fn tool-call-block [id name args]
  {:type :tool-call : id : name :arguments args})

;; @doc fen.core.types.user-message
;; kind: function
;; signature: (user-message content) -> UserMessage
;; summary: Build a {:role :user :content :timestamp} message. content is a string or [TextContent].
;; tags: types message
;; see-also: type:UserMessage
(fn user-message [content]
  {:role :user
   :content content
   :timestamp (now-ms)})

;; @doc fen.core.types.assistant-message
;; kind: function
;; signature: (assistant-message {: content : api : provider : model : usage : stop-reason : error-message}) -> AssistantMessage
;; summary: Build a canonical AssistantMessage. Content defaults to []; usage and stop-reason fall back to safe defaults; error-message is set only when provided.
;; tags: types message assistant
;; see-also: type:AssistantMessage
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

;; @doc fen.core.types.tool-result-message
;; kind: function
;; signature: (tool-result-message {: tool-call-id : tool-name : content : details : is-error?}) -> ToolResultMessage
;; summary: Build a canonical ToolResultMessage. content is always an array; details is opaque presenter payload.
;; tags: types message tool-result
;; see-also: type:ToolResultMessage
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

;; @doc fen.core.types.INCOMPLETE-STREAM-MSG
;; kind: data
;; signature: string
;; summary: Error message for a 2xx stream that closed without a terminal completion event. Shared so provider finalizers and their tests can't drift.
;; tags: types message error streaming
(local INCOMPLETE-STREAM-MSG "stream ended without a completion event")

;; @doc fen.core.types.assistant-text
;; kind: function
;; signature: (assistant-text msg) -> string
;; summary: Concatenate every TextContent block in msg.content. Returns "" if there are no text blocks.
;; tags: types message accessor
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

;; @doc fen.core.types.assistant-tool-calls
;; kind: function
;; signature: (assistant-tool-calls msg) -> [ToolCall]
;; summary: Return every :tool-call block in msg.content, in source order.
;; tags: types message accessor tool-call
(fn assistant-tool-calls [msg] (filter-blocks msg :tool-call))

;; @doc fen.core.types.assistant-thinking
;; kind: function
;; signature: (assistant-thinking msg) -> [ThinkingContent]
;; summary: Return every :thinking block in msg.content, in source order.
;; tags: types message accessor thinking
(fn assistant-thinking [msg] (filter-blocks msg :thinking))

{: now-ms
 : text-block
 : thinking-block
 : tool-call-block
 : user-message
 : assistant-message
 : tool-result-message
 : assistant-error
 : INCOMPLETE-STREAM-MSG
 : assistant-text
 : assistant-tool-calls
 : assistant-thinking}
