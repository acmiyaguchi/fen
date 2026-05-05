;; Public contract docs for canonical types, register kinds, and event
;; bus shapes. Pure data — consumed by scripts/gen-docs.fnl and
;; scripts/doc-coverage.fnl, and reusable by future introspection
;; commands.
;;
;; Field map shape:
;;   {:type "string"    ; informal type label
;;    :required true    ; default false
;;    :const :foo       ; literal-value constraint
;;    :summary "..."}
;;
;; Each top-level entry must carry at least :summary. Fields are
;; optional but encouraged for register kinds and events.

{:types
 {:Message
  {:summary "Union of UserMessage, AssistantMessage, ToolResultMessage. Stored on `agent.messages` and passed to providers in `AgentContext.messages`."
   :variants [:UserMessage :AssistantMessage :ToolResultMessage]}

  :UserMessage
  {:summary "Single user turn. Content is either a plain string or an array of TextContent blocks."
   :fields {:role {:const :user :required true}
            :content {:type "string|[TextContent]" :required true}
            :timestamp {:type "number" :required true
                        :summary "Milliseconds since epoch."}}}

  :AssistantMessage
  {:summary "Single model response. Content is always an array, even when empty."
   :fields {:role {:const :assistant :required true}
            :content {:type "[TextContent|ThinkingContent|ToolCall]" :required true}
            :api {:type "keyword"
                  :summary ":openai-completions | :openai-responses | :anthropic-messages | :openai-codex"}
            :provider {:type "keyword"
                       :summary "Registered provider :name (e.g. :openai, :anthropic)."}
            :model {:type "string"}
            :usage {:type "Usage"}
            :stop-reason {:type "StopReason"}
            :error-message {:type "string"
                            :summary "Present only when stop-reason = :error."}
            :timestamp {:type "number" :required true}}}

  :ToolResultMessage
  {:summary "Result of a single tool call, carried back to the provider on the next turn."
   :fields {:role {:const :tool-result :required true}
            :tool-call-id {:type "string" :required true
                           :summary "Matches the originating ToolCall.id."}
            :tool-name {:type "string" :required true}
            :content {:type "[TextContent]" :required true}
            :is-error? {:type "boolean" :required true}
            :details {:type "any"
                      :summary "Opaque presenter payload (UI-only)."}
            :timestamp {:type "number" :required true}}}

  :TextContent
  {:summary "Plain visible text block."
   :fields {:type {:const :text :required true}
            :text {:type "string" :required true}}}

  :ThinkingContent
  {:summary "Reasoning/extended-thinking block. Surfaces both Anthropic extended thinking and OpenAI reasoning items."
   :fields {:type {:const :thinking :required true}
            :thinking {:type "string" :required true}
            :thinking-signature {:type "string"
                                 :summary "Opaque echo signature; required for multi-turn extended thinking."}
            :redacted? {:type "boolean"
                        :summary "True when the provider redacted visible text."}}}

  :ToolCall
  {:summary "Assistant request to invoke a tool. Arguments are a parsed Lua table — providers JSON-decode wire arguments before constructing this block."
   :fields {:type {:const :tool-call :required true}
            :id {:type "string" :required true}
            :name {:type "string" :required true}
            :arguments {:type "table" :required true}}}

  :StopReason
  {:summary "Why the assistant stopped producing output."
   :enum [:stop :length :tool-use :error :aborted]}

  :Usage
  {:summary "Token usage counters returned by the provider (best-effort — providers fill what they can)."
   :fields {:input {:type "number"}
            :output {:type "number"}
            :cache-read {:type "number"}
            :cache-write {:type "number"}
            :total-tokens {:type "number"}}}

  :Tool
  {:summary "Provider-agnostic tool spec — what providers see in `AgentContext.tools`."
   :fields {:name {:type "string" :required true}
            :description {:type "string" :required true}
            :parameters {:type "JSONSchema" :required true
                         :summary "{:type :object :properties {...} :required [...]}"}}}

  :AgentTool
  {:summary "Tool extended with execution metadata for the agent loop. Registered through `(api.register :tool ...)`."
   :fields {:name {:type "string" :required true}
            :description {:type "string" :required true}
            :parameters {:type "JSONSchema" :required true}
            :label {:type "string" :summary "UI label."}
            :execute {:type "(args ?yield-fn) -> AgentToolResult" :required true}}}

  :AgentToolResult
  {:summary "Outcome of a tool execution."
   :fields {:content {:type "[TextContent]" :required true}
            :details {:type "any" :summary "Opaque presenter payload (UI-only)."}
            :is-error? {:type "boolean" :required true}}}

  :AgentContext
  {:summary "Per-call payload handed to a provider's `:complete`."
   :fields {:system-prompt {:type "string|nil"}
            :messages {:type "[Message]" :required true}
            :tools {:type "[Tool]" :required true}
            :max-tokens {:type "number" :required true}}}}

 :register-kinds
 {:tool
  {:summary "Agent tool contribution. Merged into the per-step `AgentContext.tools` and dispatched by name when the assistant emits a ToolCall."
   :fields {:name {:type "string" :required true}
            :description {:type "string" :required true}
            :parameters {:type "JSONSchema" :required true}
            :label {:type "string"}
            :execute {:type "(args ?yield-fn) -> AgentToolResult" :required true}}}

  :command
  {:summary "Slash command contribution. Looked up by name when the user submits `/<name> <args>` from a presenter."
   :fields {:name {:type "keyword|string" :required true}
            :description {:type "string"}
            :handler {:type "(args caller-state) -> any" :required true}
            :idle-only? {:type "boolean"
                         :summary "Refuse the command while the agent is busy."}
            :order {:type "number" :summary "Sort hint for `/help`."}}}

  :control
  {:summary "Keyboard/UI control surface for presenters that support typed input bindings."
   :fields {:name {:type "keyword|string" :required true}
            :handler {:type "(ctx) -> any" :required true}
            :description {:type "string"}}}

  :status
  {:summary "Status-line contributor — produces a short string for the presenter's status row."
   :fields {:name {:type "keyword|string" :required true}
            :render {:type "(ctx) -> string|nil" :required true}
            :order {:type "number"}}}

  :panel
  {:summary "Non-modal side panel contribution rendered by presenters that support panels."
   :fields {:name {:type "keyword|string" :required true}
            :title {:type "string"}
            :render {:type "(ctx) -> any" :required true}
            :enabled? {:type "(ctx) -> boolean"}}}

  :hook
  {:summary "Lifecycle hook (currently `before-tool`). Inspects a tool call before it executes."
   :fields {:before-tool {:type "(tool-name args ctx) -> any" :required true
                          :summary "Return {:block true :reason string} to veto."}}}

  :presenter
  {:summary "UI driver. Owns the input/output loop. Exactly one is active per run; the loader picks based on flags and manifest hints."
   :fields {:name {:type "keyword|string" :required true}
            :init {:type "(ctx) -> nil"}
            :run {:type "(ctx) -> nil" :required true}
            :shutdown {:type "(ctx) -> nil"}}}

  :provider
  {:summary "LLM provider contribution. See the :provider-interface contract for the required record."
   :fields {:name {:type "keyword|string" :required true}
            :api {:type "keyword" :required true
                  :summary "Protocol family (:openai-completions, :anthropic-messages, ...). Many providers may share an :api."}
            :complete {:type "(model ctx options ?on-event ?yield-fn) -> AssistantMessage" :required true}
            :convert-messages {:type "([Message]) -> [WireMessage]" :required true}
            :convert-tools {:type "([Tool]) -> [WireTool]" :required true}
            :map-stop-reason {:type "(string) -> StopReason" :required true}
            :parse-response {:type "(WireResponse) -> AssistantMessage" :required true}
            :build-body {:type "(model ctx options) -> table" :required true}}}

  :auth-backend
  {:summary "Auth credential backend. Resolves an api-key or rotates an OAuth token for one or more providers."
   :fields {:name {:type "keyword|string" :required true}
            :api-key {:type "() -> string|nil" :required true}
            :login! {:type "(opts) -> any"
                     :summary "Optional. Drives `fen --login <name>`."}
            :logout! {:type "() -> any"
                      :summary "Optional. Drives `fen --logout <name>`."}}}

  :session-backend
  {:summary "Persistence backend for canonical JSONL-style sessions. The `--session` flag selects one and `core.extensions.set-active-session-backend!` activates it."
   :fields {:name {:type "keyword|string" :required true}
            :open {:type "(opts) -> session" :required true}
            :open-existing {:type "(path opts) -> session" :required true}
            :append {:type "(session message) -> nil" :required true}
            :close {:type "(session) -> nil" :required true}
            :load {:type "(path opts) -> [Message]" :required true}
            :find {:type "(opts) -> [SessionInfo]" :required true}
            :list {:type "(opts) -> [SessionInfo]" :required true}
            :latest {:type "(opts) -> SessionInfo|nil" :required true}}}

  :prompt-fragment
  {:summary "System-prompt fragment. Either a static string or `(ctx) -> string`. Ordered by `:order` (default 90); rendered fragments are joined with blank lines. Prefer `api.prompt`; this is the underlying register kind. Core stores owner metadata in reserved :__owner and exposes public lists as :owner."
   :fields {:id {:type "keyword|string" :required true}
            :title {:type "string"}
            :description {:type "string"}
            :text {:type "string|(ctx) -> string|nil"}
            :text-or-fn {:type "string|(ctx) -> string|nil"}
            :order {:type "number"}}}}

 :events
 {:message-appended
  {:summary "Emitted by `fen.core.agent` immediately after `agent.messages` grows."
   :fields {:type {:const :message-appended :required true}
            :message {:type "Message" :required true}
            :agent {:type "Agent" :required true}
            :index {:type "number" :required true
                    :summary "1-based index of the appended message."}}}

  :agent-started
  {:summary "Emitted once per run after setup and before the first new step."
   :fields {:type {:const :agent-started :required true}
            :agent {:type "Agent" :required true}
            :provider {:type "keyword|string" :required true}
            :model {:type "string" :required true}
            :cwd {:type "string" :required true}}}

  :agent-shutdown
  {:summary "Emitted once per run during teardown. `:error` is present for crashed paths."
   :fields {:type {:const :agent-shutdown :required true}
            :agent {:type "Agent" :required true}
            :reason {:type "keyword" :required true
                     :summary ":normal | :crashed"}
            :error {:type "string"}}}

  :extension-loaded
  {:summary "Emitted by the loader for each successfully loaded extension manifest."
   :fields {:type {:const :extension-loaded :required true}
            :name {:type "string" :required true}
            :first-party? {:type "boolean"}}}

  :extension-error
  {:summary "Emitted when an extension event handler raises. Suppressed for recursive extension-error events to prevent loops."
   :fields {:type {:const :extension-error :required true}
            :owner {:type "keyword|string"}
            :event {:type "keyword|string"}
            :error {:type "string" :required true}}}

  :error
  {:summary "Generic surface error — typically command-dispatch or user-input failures."
   :fields {:type {:const :error :required true}
            :error {:type "string" :required true}}}

  :queued
  {:summary "User-line queued while the agent is busy. Consumed by the agent on natural-stop."
   :fields {:type {:const :queued :required true}
            :line {:type "string" :required true}}}

  :cancelled
  {:summary "Cooperative cancel observed; the current step appended an aborted assistant message."
   :fields {:type {:const :cancelled :required true}}}

  :set-status-info
  {:summary "Presenter-level status hint. Owners post a transient status line; nil clears."
   :fields {:type {:const :set-status-info :required true}
            :info {:type "string|nil"}}}

  :llm-start
  {:summary "Provider call beginning."
   :fields {:type {:const :llm-start :required true}
            :provider {:type "keyword"}
            :model {:type "string"}}}

  :llm-end
  {:summary "Provider call completed (success or error). The :message field carries the canonical AssistantMessage."
   :fields {:type {:const :llm-end :required true}
            :message {:type "AssistantMessage" :required true}}}

  :assistant-text
  {:summary "Final visible text emitted by the assistant. One per AssistantMessage with text blocks."
   :fields {:type {:const :assistant-text :required true}
            :text {:type "string" :required true}
            :final? {:type "boolean"}}}

  :assistant-text-delta
  {:summary "Streaming text token. Aggregated by presenters during a stream."
   :fields {:type {:const :assistant-text-delta :required true}
            :delta {:type "string" :required true}}}

  :assistant-thinking
  {:summary "Final reasoning text from the assistant (for providers that surface reasoning content)."
   :fields {:type {:const :assistant-thinking :required true}
            :text {:type "string" :required true}
            :final? {:type "boolean"}}}

  :assistant-thinking-delta
  {:summary "Streaming reasoning token."
   :fields {:type {:const :assistant-thinking-delta :required true}
            :delta {:type "string" :required true}}}

  :assistant-stream-end
  {:summary "Stream finished. Emitted once after all per-block end events for a single AssistantMessage."
   :fields {:type {:const :assistant-stream-end :required true}}}

  :tool-call
  {:summary "Tool call about to execute. Carries the canonical ToolCall block."
   :fields {:type {:const :tool-call :required true}
            :tool-call {:type "ToolCall" :required true}}}

  :tool-result
  {:summary "Tool execution finished. Carries the canonical ToolResultMessage."
   :fields {:type {:const :tool-result :required true}
            :result {:type "ToolResultMessage" :required true}}}

  ;; Provider-level streaming sub-events. Emitted by providers (or
  ;; synthesized via fen.core.llm.emit-block-events for non-streaming
  ;; providers). The agent translates these into :assistant-*-delta
  ;; events for presenters; extensions only need to subscribe at this
  ;; level for low-latency streaming UIs.
  :start
  {:summary "Provider stream opened. Marker event emitted before any block events."
   :fields {:type {:const :start :required true}}}

  :text-start
  {:summary "Provider stream: a TextContent block is starting."
   :fields {:type {:const :text-start :required true}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}}}

  :text-delta
  {:summary "Provider stream: incremental text token within the open block."
   :fields {:type {:const :text-delta :required true}
            :content-index {:type "number" :required true}
            :delta {:type "string" :required true}}}

  :text-end
  {:summary "Provider stream: TextContent block closed; full text supplied."
   :fields {:type {:const :text-end :required true}
            :content-index {:type "number" :required true}
            :content {:type "string" :required true}}}

  :thinking-start
  {:summary "Provider stream: a ThinkingContent block is starting."
   :fields {:type {:const :thinking-start :required true}
            :content-index {:type "number" :required true}}}

  :thinking-delta
  {:summary "Provider stream: incremental reasoning token within the open block."
   :fields {:type {:const :thinking-delta :required true}
            :content-index {:type "number" :required true}
            :delta {:type "string" :required true}}}

  :thinking-end
  {:summary "Provider stream: ThinkingContent block closed; full text supplied."
   :fields {:type {:const :thinking-end :required true}
            :content-index {:type "number" :required true}
            :content {:type "string" :required true}}}

  :tool-call-start
  {:summary "Provider stream: a ToolCall block is starting; arguments not yet known."
   :fields {:type {:const :tool-call-start :required true}
            :content-index {:type "number" :required true}}}

  :tool-call-delta
  {:summary "Provider stream: incremental JSON-text fragment for the open ToolCall arguments. Some providers stream arguments token-by-token; consumers may concatenate."
   :fields {:type {:const :tool-call-delta :required true}
            :content-index {:type "number" :required true}
            :delta {:type "string" :required true}}}

  :tool-call-end
  {:summary "Provider stream: ToolCall block closed; complete canonical ToolCall block supplied."
   :fields {:type {:const :tool-call-end :required true}
            :content-index {:type "number" :required true}
            :tool-call {:type "ToolCall" :required true}}}

  :done
  {:summary "Provider stream: terminal event for a successful AssistantMessage."
   :fields {:type {:const :done :required true}
            :message {:type "AssistantMessage" :required true}}}

  ;; Presenter / extension internals. These are not part of the agent
  ;; loop contract but cross-extension subscribers depend on them, so
  ;; the shapes are documented here.
  :user
  {:summary "User-submitted line accepted by the presenter input layer. Distinct from :queued (which fires when the line is *queued* during a busy turn)."
   :fields {:type {:const :user :required true}
            :line {:type "string" :required true}}}

  :reset-conversation
  {:summary "Presenter signal that the active conversation should be cleared (used by /new)."
   :fields {:type {:const :reset-conversation :required true}}}

  :reinit-presenter
  {:summary "Presenter signal that the UI should be torn down and re-initialized (used by /reload)."
   :fields {:type {:const :reinit-presenter :required true}}}

  :redraw
  {:summary "Presenter hint that a registered panel needs to be repainted."
   :fields {:type {:const :redraw :required true}}}

  :dismiss
  {:summary "Presenter signal that an open overlay/picker should close."
   :fields {:type {:const :dismiss :required true}}}

  :info
  {:summary "Transient informational message intended for the presenter status row or panel."
   :fields {:type {:const :info :required true}
            :info {:type "string"}
            :text {:type "string"}}}}

 :interfaces
 {:provider
  {:summary "Required record shape for `(api.register :provider ...)`. See the :provider register-kind for field details."
   :methods [:complete :convert-messages :convert-tools :map-stop-reason :parse-response :build-body]
   :see-also [:register-kinds.provider]}

  :auth-backend
  {:summary "Required record shape for `(api.register :auth-backend ...)`."
   :methods [:api-key]
   :optional-methods [:login! :logout!]
   :see-also [:register-kinds.auth-backend]}

  :session-backend
  {:summary "Required record shape for `(api.register :session-backend ...)`."
   :methods [:open :open-existing :append :close :load :find :list :latest]
   :see-also [:register-kinds.session-backend]}}}
