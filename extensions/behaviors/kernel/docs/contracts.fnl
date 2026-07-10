;; Public contract docs for canonical types, register kinds, and event
;; bus shapes. Pure data — consumed by scripts/docs/gen-docs.fnl and
;; scripts/docs/doc-coverage.fnl, and reusable by future introspection
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

;; @doc fen.extensions.docs.contracts.types
;; kind: data
;; signature: table
;; summary: Canonical message, content, tool, usage, and agent-context type contracts shared by providers, tools, sessions, and docs.
;; tags: docs contracts types
{:types
 {:Message
  {:summary "Union of UserMessage, AssistantMessage, ToolResultMessage. Stored on `agent.messages` and passed to providers in `AgentContext.messages`."
   :variants [:UserMessage :AssistantMessage :ToolResultMessage]}

  :UserMessage
  {:summary "Single user turn. Content is either a plain string or an array of TextContent blocks."
   :fields {:role {:const :user :required true
                   :summary "Message role discriminator for user-authored turns."}
            :content {:type "string|[TextContent]" :required true
                      :summary "Visible user input as plain text or canonical text content blocks."}
            :timestamp {:type "number" :required true
                        :summary "Milliseconds since epoch."}}}

  :AssistantMessage
  {:summary "Single model response. Content is always an array, even when empty."
   :fields {:role {:const :assistant :required true
                   :summary "Message role discriminator for model-authored turns."}
            :content {:type "[TextContent|ThinkingContent|ToolCall]" :required true
                      :summary "Ordered assistant output blocks, including visible text, reasoning, and tool calls."}
            :api {:type "keyword"
                  :summary ":openai-completions | :openai-responses | :anthropic-messages | :openai-codex"}
            :provider {:type "keyword"
                       :summary "Registered provider :name (e.g. :openai, :anthropic)."}
            :model {:type "string"
                    :summary "Provider model identifier that produced this response."}
            :usage {:type "Usage"
                    :summary "Optional token accounting returned by the provider for this response."}
            :stop-reason {:type "StopReason"
                          :summary "Normalized reason the provider stopped generation."}
            :error-message {:type "string"
                            :summary "Present only when stop-reason = :error."}
            :timestamp {:type "number" :required true
                        :summary "Milliseconds since epoch when the assistant message was recorded."}}}

  :ToolResultMessage
  {:summary "Result of a single tool call, carried back to the provider on the next turn."
   :fields {:role {:const :tool-result :required true
                   :summary "Message role discriminator for tool execution results."}
            :tool-call-id {:type "string" :required true
                           :summary "Matches the originating ToolCall.id."}
            :tool-name {:type "string" :required true
                        :summary "Tool name that produced the result, copied from the originating call."}
            :content {:type "[TextContent]" :required true
                      :summary "Tool output blocks returned to the provider on the next turn."}
            :is-error? {:type "boolean" :required true
                        :summary "True when the tool result should be treated as an error observation."}
            :details {:type "any"
                      :summary "Opaque presenter payload (UI-only)."}
            :timestamp {:type "number" :required true
                        :summary "Milliseconds since epoch when the tool result was recorded."}}}

  :TextContent
  {:summary "Plain visible text block."
   :fields {:type {:const :text :required true
                   :summary "Content-block discriminator for visible text."}
            :text {:type "string" :required true
                   :summary "Visible UTF-8 text payload."}}}

  :ThinkingContent
  {:summary "Reasoning/extended-thinking block. Surfaces both Anthropic extended thinking and OpenAI reasoning items."
   :fields {:type {:const :thinking :required true
                   :summary "Content-block discriminator for provider reasoning text."}
            :thinking {:type "string" :required true
                       :summary "Reasoning or extended-thinking text emitted by the provider."}
            :thinking-signature {:type "string"
                                 :summary "Opaque echo signature; required for multi-turn extended thinking."}
            :redacted? {:type "boolean"
                        :summary "True when the provider redacted visible text."}}}

  :ToolCall
  {:summary "Assistant request to invoke a tool. Arguments are a parsed Lua table — providers JSON-decode wire arguments before constructing this block."
   :fields {:type {:const :tool-call :required true
                   :summary "Content-block discriminator for tool invocation requests."}
            :id {:type "string" :required true
                 :summary "Provider- or agent-generated id used to match the eventual tool result."}
            :name {:type "string" :required true
                   :summary "Registered tool name to execute."}
            :arguments {:type "table" :required true
                        :summary "Decoded argument table validated by the target tool implementation."}}}

  :StopReason
  {:summary "Why the assistant stopped producing output."
   :enum [:stop :length :tool-use :error :aborted]}

  :Usage
  {:summary "Token usage counters returned by the provider (best-effort — providers fill what they can)."
   :fields {:input {:type "number"
                    :summary "Input or prompt tokens counted for the response."}
            :output {:type "number"
                     :summary "Generated output tokens counted for the response."}
            :cache-read {:type "number"
                         :summary "Provider cache-read tokens credited for the response."}
            :cache-write {:type "number"
                          :summary "Provider cache-write tokens billed or recorded for the response."}
            :total-tokens {:type "number"
                           :summary "Provider-reported total tokens, or the best available aggregate."}
            :latency-ms {:type "number"
                         :summary "Wall-clock milliseconds for the provider round-trip (agent-measured monotonic delta, not provider-reported). Optional; absent on older transcripts."}}}

  :Tool
  {:summary "Provider-agnostic tool spec — what providers see in `AgentContext.tools`."
   :fields {:name {:type "string" :required true
                   :summary "Provider-visible tool name used in tool-call blocks."}
            :description {:type "string" :required true
                          :summary "Provider-visible explanation of when and how to call the tool."}
            :parameters {:type "JSONSchema" :required true
                         :summary "{:type :object :properties {...} :required [...]}"}}}

  :AgentTool
  {:summary "Tool extended with execution metadata for the agent loop. Registered through `(api.register :tool ...)`."
   :fields {:name {:type "string" :required true
                   :summary "Registry name used to merge and dispatch the tool."}
            :description {:type "string" :required true
                          :summary "Provider-facing description included in the tool schema."}
            :parameters {:type "JSONSchema" :required true
                         :summary "Provider-facing argument schema used for validation and prompting."}
            :label {:type "string" :summary "UI label."}
            :execute {:type "(args ?yield-fn) -> AgentToolResult" :required true
                      :summary "Runtime callback that executes the tool with decoded arguments."}}}

  :AgentToolResult
  {:summary "Outcome of a tool execution."
   :fields {:content {:type "[TextContent]" :required true
                      :summary "Text content returned to the provider as the tool observation."}
            :details {:type "any" :summary "Opaque presenter payload (UI-only)."}
            :is-error? {:type "boolean" :required true
                        :summary "True when the tool observation represents a failed call."}}}

  :AgentContext
  {:summary "Per-call payload handed to a provider's `:complete`."
   :fields {:system-prompt {:type "string|nil"
                            :summary "Fully rendered system prompt for the current step, or nil when omitted."}
            :messages {:type "[Message]" :required true
                       :summary "Canonical conversation history to convert into provider wire format."}
            :tools {:type "[Tool]" :required true
                    :summary "Provider-visible tool specs available for this step."}
            :max-tokens {:type "number" :required true
                         :summary "Maximum output token budget requested for the provider call."}}}}

 ;; @doc fen.extensions.docs.contracts.register-kinds
 ;; kind: data
 ;; signature: table
 ;; summary: Extension registration kind contracts describing required fields for tools, commands, providers, presenters, panels, hooks, and prompt fragments.
 ;; tags: docs contracts extensions register
 :register-kinds
 {:tool
  {:summary "Agent tool contribution. Merged into the per-step `AgentContext.tools` and dispatched by name when the assistant emits a ToolCall."
   :fields {:name {:type "string" :required true
                   :summary "Unique tool name exposed to providers and matched against ToolCall.name."}
            :description {:type "string" :required true
                          :summary "Provider-facing guidance explaining when the model should call this tool."}
            :parameters {:type "JSONSchema" :required true
                         :summary "JSON object schema describing the tool arguments providers may emit."}
            :label {:type "string"
                    :summary "Optional short UI label shown by presenters while the tool runs."}
            :execute {:type "(args ?yield-fn) -> AgentToolResult" :required true
                      :summary "Runtime callback that executes decoded arguments and returns canonical tool content."}}}

  :command
  {:summary "Slash command contribution. Looked up by name when the user submits `/<name> <args>` from a presenter."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Command name without the leading slash."}
            :description {:type "string"
                          :summary "Human-readable command help shown in command listings and docs."}
            :handler {:type "(args caller-state) -> any" :required true
                      :summary "Callback invoked with raw command arguments and the caller's runtime state."}
            :idle-only? {:type "boolean"
                         :summary "Refuse the command while the agent is busy."}
            :order {:type "number" :summary "Sort hint for `/help`."}}}

  :control
  {:summary "Keyboard/UI control surface for presenters that support typed input bindings."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Stable control name exposed to presenter help and docs."}
            :handler {:type "(ctx) -> any" :required true
                      :summary "Callback invoked by the presenter when the control is activated."}
            :description {:type "string"
                          :summary "Human-readable explanation of the control's UI effect."}}}

  :status
  {:summary "Status-line contributor — produces a short string for the presenter's status row."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Stable status item name used for sorting, diagnostics, and docs."}
            :render {:type "(ctx) -> string|nil" :required true
                     :summary "Callback returning the current status text, or nil/empty text to hide it."}
            :order {:type "number"
                    :summary "Sort hint within the status side; lower values render earlier."}}}

  :panel
  {:summary "Non-modal side panel contribution rendered by presenters that support panels."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Stable panel name used for toggles, docs, and diagnostics."}
            :title {:type "string"
                    :summary "Optional display title when the presenter renders panel chrome."}
            :render {:type "(ctx) -> any" :required true
                     :summary "Callback returning rows or presenter-specific content for the panel body."}
            :enabled? {:type "(ctx) -> boolean"
                       :summary "Optional predicate that hides the panel without unregistering it."}}}

  :hook
  {:summary "Lifecycle hook (currently `before-tool`). Inspects a tool call before it executes."
   :fields {:before-tool {:type "(tool-name args ctx) -> any" :required true
                          :summary "Return {:block true :reason string} to veto."}}}

  :input-handler
  {:summary "Ordered handler for non-slash user input, run before a turn starts. An alternative to the event bus for input transforms/intercepts: handlers run in ascending :order and return structured actions rather than relying on ignored emit return values."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Stable handler name used for ordering, diagnostics, and docs."}
            :order {:type "number"
                    :summary "Ascending sort hint; lower runs first. Defaults to 100. The default steering handler runs at 1000."}
            :handle {:type "(input ctx) -> action" :required true
                     :summary "Given input {:kind :user-input :text string} and ctx {:busy? bool :state runtime-state}, return an action: {:action :continue :input modified} to pass on, {:action :consumed}, {:action :ignore}, {:action :start :text text}, {:action :queued :queue :steering|:follow-up :text text}, or {:action :error :error msg}."}}}

  :introspect
  {:summary "Read-only extension state snapshot provider. Collected on demand for agent_state, /extensions, and runtime diagnostics."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Owner-scoped snapshot name. Multiple extensions may reuse the same name."}
            :description {:type "string"
                          :summary "Human-readable description shown by diagnostics and docs."}
            :snapshot {:type "(ctx) -> table" :required true
                       :summary "Cheap, side-effect-free thunk returning JSON-friendly data. It is pcall-isolated and should not expose secrets."}}}

  :presenter
  {:summary "UI driver. Owns the input/output loop. Exactly one is active per run; the loader picks based on flags and manifest hints."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Presenter name selected by CLI flags or extension activation rules."}
            :init {:type "(ctx) -> nil"
                   :summary "Optional lifecycle callback run before the presenter loop starts."}
            :run {:type "(ctx) -> nil" :required true
                  :summary "Main input/output loop for the selected presenter."}
            :shutdown {:type "(ctx) -> nil"
                       :summary "Optional lifecycle callback used to release terminal, socket, or other UI resources."}}}

  :provider
  {:summary "LLM provider contribution. See the :provider-interface contract for the required record."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Provider name selected by settings or CLI options."}
            :api {:type "keyword" :required true
                  :summary "Protocol family (:openai-completions, :anthropic-messages, ...). Many providers may share an :api."}
            :complete {:type "(model ctx options ?on-event ?yield-fn) -> AssistantMessage" :required true
                       :summary "High-level provider entry point that runs one model turn and returns a canonical assistant message."}
            :convert-messages {:type "([Message]) -> [WireMessage]" :required true
                               :summary "Translate canonical conversation messages into this provider's wire message format."}
            :convert-tools {:type "([Tool]) -> [WireTool]" :required true
                            :summary "Translate canonical tool specs into this provider's wire tool schema."}
            :map-stop-reason {:type "(string) -> StopReason" :required true
                              :summary "Normalize provider stop reasons into fen's canonical StopReason enum."}
            :parse-response {:type "(WireResponse) -> AssistantMessage" :required true
                             :summary "Convert a non-streaming provider response payload into an AssistantMessage."}
            :build-body {:type "(model ctx options) -> table" :required true
                         :summary "Build the provider request body from a model id, AgentContext, and call options."}}}

  :auth-backend
  {:summary "Auth credential backend. Resolves an api-key or rotates an OAuth token for one or more providers."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Auth backend name selected by provider configuration or CLI login/logout flags."}
            :api-key {:type "() -> string|nil" :required true
                      :summary "Return the current bearer/API key, refreshing or loading secrets as needed."}
            :login! {:type "(opts) -> any"
                     :summary "Optional. Drives `fen --login <name>`."}
            :logout! {:type "() -> any"
                      :summary "Optional. Drives `fen --logout <name>`."}}}

  :session-backend
  {:summary "Persistence backend for canonical JSONL-style sessions. The `--session` flag selects one and `fen.core.extensions.register.session_backend.set-active!` activates it."
   :fields {:name {:type "keyword|string" :required true
                   :summary "Session backend name selected by CLI flags or extension configuration."}
            :open {:type "(opts) -> session" :required true
                   :summary "Create or open the active session for a new run."}
            :open-existing {:type "(path opts) -> session" :required true
                            :summary "Open an existing session file or directory for appending."}
            :append {:type "(session message) -> nil" :required true
                     :summary "Persist one canonical Message to the active session."}
            :close {:type "(session) -> nil" :required true
                    :summary "Flush and release backend resources for an open session."}
            :load {:type "(path opts) -> [Message]" :required true
                   :summary "Read canonical messages from a stored session path."}
            :find {:type "(opts) -> [SessionInfo]" :required true
                   :summary "Search sessions using backend-specific filters."}
            :list {:type "(opts) -> [SessionInfo]" :required true
                   :summary "List sessions visible to this backend in a stable display order."}
            :latest {:type "(opts) -> SessionInfo|nil" :required true
                     :summary "Return the newest matching session, if any."}}}}


 ;; @doc fen.extensions.docs.contracts.events
 ;; kind: data
 ;; signature: table
 ;; summary: Event bus contract table documenting emitted runtime event shapes and fields consumed by presenters and extensions.
 ;; tags: docs contracts events bus
 :events
 {:message-appended
  {:summary "Emitted by `fen.core.agent` immediately after `agent.messages` grows."
   :fields {:type {:const :message-appended :required true
       :summary "Event discriminator for :message-appended events."}
            :message {:type "Message" :required true
                      :summary "Canonical message that was appended to the conversation."}
            :agent {:type "Agent" :required true
                    :summary "Agent instance associated with the event."}
            :index {:type "number" :required true
                    :summary "1-based index of the appended message."}}}

  :agent-started
  {:summary "Emitted once per run after setup and before the first new step."
   :fields {:type {:const :agent-started :required true
       :summary "Event discriminator for :agent-started events."}
            :agent {:type "Agent" :required true
                    :summary "Agent instance associated with the event."}
            :provider {:type "keyword|string" :required true
                       :summary "Provider name selected for the active run."}
            :model {:type "string" :required true
                  :summary "Model identifier selected for the active run."}
            :cwd {:type "string" :required true
                :summary "Working directory for the active agent run."}}}

  :agent-turn-complete
  {:summary "Emitted once per submitted user turn after the agent coroutine finishes and the presenter busy flag has been cleared."
   :fields {:type {:const :agent-turn-complete :required true
       :summary "Event discriminator for :agent-turn-complete events."}
            :agent {:type "Agent" :required true
                    :summary "Agent instance associated with the completed turn."}
            :status {:type "keyword" :required true
                     :summary ":ok | :cancelled | :error"}
            :result {:type "string"
                     :summary "Final visible assistant text for successful or cancelled turns, when available."}
            :error {:type "string"
                    :summary "Error summary when the turn ended with :status :error."}
            :message-count {:type "number" :required true
                            :summary "Conversation message count after the turn finished."}}}

  :agent-shutdown
  {:summary "Emitted once per run during teardown. `:error` is present for crashed paths."
   :fields {:type {:const :agent-shutdown :required true
       :summary "Event discriminator for :agent-shutdown events."}
            :agent {:type "Agent" :required true
                    :summary "Agent instance associated with the event."}
            :reason {:type "keyword" :required true
                     :summary ":normal | :crashed"}
            :error {:type "string"
                    :summary "Crash details when shutdown follows an error path."}}}

  :extension-loaded
  {:summary "Emitted by the loader for each successfully loaded extension manifest."
   :fields {:type {:const :extension-loaded :required true
       :summary "Event discriminator for :extension-loaded events."}
            :name {:type "string" :required true
                  :summary "Extension manifest name that was loaded."}
            :first-party? {:type "boolean"
                           :summary "True when the loaded extension came from fen's bundled extension set."}}}

  :extension-error
  {:summary "Emitted when an extension event handler raises. Suppressed for recursive extension-error events to prevent loops."
   :fields {:type {:const :extension-error :required true
       :summary "Event discriminator for :extension-error events."}
            :owner {:type "keyword|string"
                    :summary "Extension owner whose handler raised, when known."}
            :event {:type "keyword|string"
                    :summary "Original event being handled when the extension error occurred."}
            :error {:type "string" :required true
                    :summary "Human-readable error message for presenters and logs."}}}

  :error
  {:summary "Generic surface error — typically command-dispatch or user-input failures."
   :fields {:type {:const :error :required true
       :summary "Event discriminator for :error events."}
            :error {:type "string" :required true
                    :summary "Human-readable error message for presenters and logs."}}}

  :queued
  {:summary "User-line queued while the agent is busy. Consumed by the agent on natural-stop."
   :fields {:type {:const :queued :required true
       :summary "Event discriminator for :queued events."}
            :line {:type "string" :required true
                  :summary "Raw user input line associated with the event."}}}

  :cancelled
  {:summary "Cooperative cancel observed; the current step appended an aborted assistant message."
   :fields {:type {:const :cancelled :required true
       :summary "Event discriminator for :cancelled events."}}}

  :set-status-info
  {:summary "Presenter-level status hint. Owners post a transient status line; nil clears."
   :fields {:type {:const :set-status-info :required true
       :summary "Event discriminator for :set-status-info events."}
            :info {:type "string|nil"
                  :summary "Transient status text to show, or nil to clear it."}}}

  :llm-start
  {:summary "Provider call beginning."
   :fields {:type {:const :llm-start :required true
       :summary "Event discriminator for :llm-start events."}
            :provider {:type "keyword"
                       :summary "Provider name for the outbound LLM call, when known."}
            :model {:type "string"
                  :summary "Model identifier used for the provider request, when known."}}}

  :llm-end
  {:summary "Provider call completed (success or error). The :message field carries the canonical AssistantMessage."
   :fields {:type {:const :llm-end :required true
       :summary "Event discriminator for :llm-end events."}
            :message {:type "AssistantMessage" :required true
                      :summary "Canonical assistant message produced by the provider stream."}}}

  :assistant-text
  {:summary "Final visible text emitted by the assistant. One per AssistantMessage with text blocks."
   :fields {:type {:const :assistant-text :required true
       :summary "Event discriminator for :assistant-text events."}
            :text {:type "string" :required true
                  :summary "Complete assistant text payload for this event."}
            :final? {:type "boolean"
                    :summary "True when this is the final aggregate payload for the current block."}}}

  :assistant-text-delta
  {:summary "Streaming text token. Aggregated by presenters during a stream."
   :fields {:type {:const :assistant-text-delta :required true
       :summary "Event discriminator for :assistant-text-delta events."}
            :delta {:type "string" :required true
                   :summary "Incremental streamed text fragment for the open content block."}}}

  :assistant-thinking
  {:summary "Final reasoning text from the assistant (for providers that surface reasoning content)."
   :fields {:type {:const :assistant-thinking :required true
       :summary "Event discriminator for :assistant-thinking events."}
            :text {:type "string" :required true
                  :summary "Complete assistant text payload for this event."}
            :final? {:type "boolean"
                    :summary "True when this is the final aggregate payload for the current block."}}}

  :assistant-thinking-delta
  {:summary "Streaming reasoning token."
   :fields {:type {:const :assistant-thinking-delta :required true
       :summary "Event discriminator for :assistant-thinking-delta events."}
            :delta {:type "string" :required true
                   :summary "Incremental streamed text fragment for the open content block."}}}

  :assistant-stream-end
  {:summary "Stream finished. Emitted once after all per-block end events for a single AssistantMessage."
   :fields {:type {:const :assistant-stream-end :required true
       :summary "Event discriminator for :assistant-stream-end events."}}}

  :tool-call
  {:summary "Tool call about to execute. Carries the canonical ToolCall block."
   :fields {:type {:const :tool-call :required true
       :summary "Event discriminator for :tool-call events."}
            :tool-call {:type "ToolCall" :required true
                        :summary "Canonical tool-call block associated with this event."}}}

  :tool-result
  {:summary "Tool execution finished. Carries the canonical ToolResultMessage."
   :fields {:type {:const :tool-result :required true
       :summary "Event discriminator for :tool-result events."}
            :result {:type "ToolResultMessage" :required true
                     :summary "Canonical tool-result message produced by the tool executor."}}}

  ;; Provider-level streaming sub-events. Emitted by providers (or
  ;; synthesized from the final message by non-streaming providers,
  ;; as the mock adapter does). The agent translates these into :assistant-*-delta
  ;; events for presenters; extensions only need to subscribe at this
  ;; level for low-latency streaming UIs.
  :start
  {:summary "Provider stream opened. Marker event emitted before any block events."
   :fields {:type {:const :start :required true
       :summary "Event discriminator for :start events."}}}

  :text-start
  {:summary "Provider stream: a TextContent block is starting."
   :fields {:type {:const :text-start :required true
       :summary "Event discriminator for :text-start events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}}}

  :text-delta
  {:summary "Provider stream: incremental text token within the open block."
   :fields {:type {:const :text-delta :required true
       :summary "Event discriminator for :text-delta events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}
            :delta {:type "string" :required true
                   :summary "Incremental streamed text fragment for the open content block."}}}

  :text-end
  {:summary "Provider stream: TextContent block closed; full text supplied."
   :fields {:type {:const :text-end :required true
       :summary "Event discriminator for :text-end events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}
            :content {:type "string" :required true
                      :summary "Complete text or thinking content for the closed stream block."}}}

  :thinking-start
  {:summary "Provider stream: a ThinkingContent block is starting."
   :fields {:type {:const :thinking-start :required true
       :summary "Event discriminator for :thinking-start events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}}}

  :thinking-delta
  {:summary "Provider stream: incremental reasoning token within the open block."
   :fields {:type {:const :thinking-delta :required true
       :summary "Event discriminator for :thinking-delta events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}
            :delta {:type "string" :required true
                   :summary "Incremental streamed text fragment for the open content block."}}}

  :thinking-end
  {:summary "Provider stream: ThinkingContent block closed; full text supplied."
   :fields {:type {:const :thinking-end :required true
       :summary "Event discriminator for :thinking-end events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}
            :content {:type "string" :required true
                      :summary "Complete text or thinking content for the closed stream block."}}}

  :tool-call-start
  {:summary "Provider stream: a ToolCall block is starting; arguments not yet known."
   :fields {:type {:const :tool-call-start :required true
       :summary "Event discriminator for :tool-call-start events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}}}

  :tool-call-delta
  {:summary "Provider stream: incremental JSON-text fragment for the open ToolCall arguments. Some providers stream arguments token-by-token; consumers may concatenate."
   :fields {:type {:const :tool-call-delta :required true
       :summary "Event discriminator for :tool-call-delta events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}
            :delta {:type "string" :required true
                   :summary "Incremental streamed text fragment for the open content block."}}}

  :tool-call-end
  {:summary "Provider stream: ToolCall block closed; complete canonical ToolCall block supplied."
   :fields {:type {:const :tool-call-end :required true
       :summary "Event discriminator for :tool-call-end events."}
            :content-index {:type "number" :required true
                            :summary "Position within the assistant's content array."}
            :tool-call {:type "ToolCall" :required true
                        :summary "Canonical tool-call block associated with this event."}}}

  :done
  {:summary "Provider stream: terminal event for a successful AssistantMessage."
   :fields {:type {:const :done :required true
       :summary "Event discriminator for :done events."}
            :message {:type "AssistantMessage" :required true
                      :summary "Canonical assistant message produced by the provider stream."}}}

  :compaction-summary
  {:summary "Context compaction completed and produced a summary for older messages."
   :fields {:type {:const :compaction-summary :required true
       :summary "Event discriminator for :compaction-summary events."}
            :summary {:type "string" :required true
                      :summary "Summary text installed into the compacted model context."}
            :tokens-before {:type "number"
                            :summary "Approximate context tokens before compaction."}
            :tokens-after {:type "number"
                           :summary "Approximate context tokens after compaction."}
            :messages-summarized {:type "number"
                                  :summary "Number of older messages summarized."}
            :messages-kept {:type "number"
                            :summary "Number of recent messages kept verbatim."}
            :guidance {:type "string"
                       :summary "Optional user guidance supplied to /compact."}
            :trigger {:type "keyword"
                      :summary "Why compaction ran, such as :manual or :agent."}
            :agent {:type "Agent"
                    :summary "Agent whose context was compacted; used to scope orchestration events."}}}

  ;; Presenter / extension internals. These are not part of the agent
  ;; loop contract but cross-extension subscribers depend on them, so
  ;; the shapes are documented here.
  :user
  {:summary "User-submitted line accepted by the presenter input layer. Distinct from :queued (which fires when the line is *queued* during a busy turn)."
   :fields {:type {:const :user :required true
       :summary "Event discriminator for :user events."}
            :line {:type "string" :required true
                  :summary "Raw user input line associated with the event."}}}

  :reset-conversation
  {:summary "Presenter signal that the active conversation should be cleared (used by /new)."
   :fields {:type {:const :reset-conversation :required true
       :summary "Event discriminator for :reset-conversation events."}}}

  :reinit-presenter
  {:summary "Presenter signal that the UI should be torn down and re-initialized (used by /reload)."
   :fields {:type {:const :reinit-presenter :required true
       :summary "Event discriminator for :reinit-presenter events."}}}

  :redraw
  {:summary "Presenter hint that a registered panel needs to be repainted."
   :fields {:type {:const :redraw :required true
       :summary "Event discriminator for :redraw events."}}}

  :dismiss
  {:summary "Presenter signal that an open overlay/picker should close."
   :fields {:type {:const :dismiss :required true
       :summary "Event discriminator for :dismiss events."}}}

  :info
  {:summary "Transient informational message intended for the presenter status row or panel."
   :fields {:type {:const :info :required true
       :summary "Event discriminator for :info events."}
            :info {:type "string"
                  :summary "Human-readable informational message payload."}
            :text {:type "string"
                  :summary "Alternative human-readable informational text."}}}}

 ;; @doc fen.extensions.docs.contracts.interfaces
 ;; kind: data
 ;; signature: table
 ;; summary: Interface contract table for provider, auth backend, session backend, and presenter records.
 ;; tags: docs contracts interfaces providers sessions
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
