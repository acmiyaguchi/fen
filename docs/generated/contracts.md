# Fen contracts

The non-function public surface: canonical types, extension
register kinds, event-bus shapes, and provider/auth/session
interfaces.

## Register kinds

### `auth-backend`
Auth credential backend. Resolves an api-key or rotates an OAuth token for one or more providers.

- `:api-key` `() -> string|nil` (required)
- `:login!` `(opts) -> any` — Optional. Drives `fen --login <name>`.
- `:logout!` `() -> any` — Optional. Drives `fen --logout <name>`.
- `:name` `keyword|string` (required)

### `command`
Slash command contribution. Looked up by name when the user submits `/<name> <args>` from a presenter.

- `:description` `string`
- `:handler` `(args caller-state) -> any` (required)
- `:idle-only?` `boolean` — Refuse the command while the agent is busy.
- `:name` `keyword|string` (required)
- `:order` `number` — Sort hint for `/help`.

### `control`
Keyboard/UI control surface for presenters that support typed input bindings.

- `:description` `string`
- `:handler` `(ctx) -> any` (required)
- `:name` `keyword|string` (required)

### `hook`
Lifecycle hook (currently `before-tool`). Inspects a tool call before it executes.

- `:before-tool` `(tool-name args ctx) -> any` (required) — Return {:block true :reason string} to veto.

### `panel`
Non-modal side panel contribution rendered by presenters that support panels.

- `:enabled?` `(ctx) -> boolean`
- `:name` `keyword|string` (required)
- `:render` `(ctx) -> any` (required)
- `:title` `string`

### `presenter`
UI driver. Owns the input/output loop. Exactly one is active per run; the loader picks based on flags and manifest hints.

- `:init` `(ctx) -> nil`
- `:name` `keyword|string` (required)
- `:run` `(ctx) -> nil` (required)
- `:shutdown` `(ctx) -> nil`

### `prompt-fragment`
System-prompt fragment. Either a static string or `(ctx) -> string`. Ordered by `:order` (default 90); rendered fragments are joined with blank lines. Prefer `api.prompt`; this is the underlying register kind. Core stores owner metadata in reserved :__owner and exposes public lists as :owner.

- `:description` `string`
- `:id` `keyword|string` (required)
- `:order` `number`
- `:text` `string|(ctx) -> string|nil`
- `:text-or-fn` `string|(ctx) -> string|nil`
- `:title` `string`

### `provider`
LLM provider contribution. See the :provider-interface contract for the required record.

- `:api` `keyword` (required) — Protocol family (:openai-completions, :anthropic-messages, ...). Many providers may share an :api.
- `:build-body` `(model ctx options) -> table` (required)
- `:complete` `(model ctx options ?on-event ?yield-fn) -> AssistantMessage` (required)
- `:convert-messages` `([Message]) -> [WireMessage]` (required)
- `:convert-tools` `([Tool]) -> [WireTool]` (required)
- `:map-stop-reason` `(string) -> StopReason` (required)
- `:name` `keyword|string` (required)
- `:parse-response` `(WireResponse) -> AssistantMessage` (required)

### `session-backend`
Persistence backend for canonical JSONL-style sessions. The `--session` flag selects one and `core.extensions.set-active-session-backend!` activates it.

- `:append` `(session message) -> nil` (required)
- `:close` `(session) -> nil` (required)
- `:find` `(opts) -> [SessionInfo]` (required)
- `:latest` `(opts) -> SessionInfo|nil` (required)
- `:list` `(opts) -> [SessionInfo]` (required)
- `:load` `(path opts) -> [Message]` (required)
- `:name` `keyword|string` (required)
- `:open` `(opts) -> session` (required)
- `:open-existing` `(path opts) -> session` (required)

### `status`
Status-line contributor — produces a short string for the presenter's status row.

- `:name` `keyword|string` (required)
- `:order` `number`
- `:render` `(ctx) -> string|nil` (required)

### `tool`
Agent tool contribution. Merged into the per-step `AgentContext.tools` and dispatched by name when the assistant emits a ToolCall.

- `:description` `string` (required)
- `:execute` `(args ?yield-fn) -> AgentToolResult` (required)
- `:label` `string`
- `:name` `string` (required)
- `:parameters` `JSONSchema` (required)

## Events

### `agent-shutdown`
Emitted once per run during teardown. `:error` is present for crashed paths.

- `:agent` `Agent` (required)
- `:error` `string`
- `:reason` `keyword` (required) — :normal | :crashed
- `:type` `:agent-shutdown` (required)

### `agent-started`
Emitted once per run after setup and before the first new step.

- `:agent` `Agent` (required)
- `:cwd` `string` (required)
- `:model` `string` (required)
- `:provider` `keyword|string` (required)
- `:type` `:agent-started` (required)

### `assistant-stream-end`
Stream finished. Emitted once after all per-block end events for a single AssistantMessage.

- `:type` `:assistant-stream-end` (required)

### `assistant-text`
Final visible text emitted by the assistant. One per AssistantMessage with text blocks.

- `:final?` `boolean`
- `:text` `string` (required)
- `:type` `:assistant-text` (required)

### `assistant-text-delta`
Streaming text token. Aggregated by presenters during a stream.

- `:delta` `string` (required)
- `:type` `:assistant-text-delta` (required)

### `assistant-thinking`
Final reasoning text from the assistant (for providers that surface reasoning content).

- `:final?` `boolean`
- `:text` `string` (required)
- `:type` `:assistant-thinking` (required)

### `assistant-thinking-delta`
Streaming reasoning token.

- `:delta` `string` (required)
- `:type` `:assistant-thinking-delta` (required)

### `cancelled`
Cooperative cancel observed; the current step appended an aborted assistant message.

- `:type` `:cancelled` (required)

### `dismiss`
Presenter signal that an open overlay/picker should close.

- `:type` `:dismiss` (required)

### `done`
Provider stream: terminal event for a successful AssistantMessage.

- `:message` `AssistantMessage` (required)
- `:type` `:done` (required)

### `error`
Generic surface error — typically command-dispatch or user-input failures.

- `:error` `string` (required)
- `:type` `:error` (required)

### `extension-error`
Emitted when an extension event handler raises. Suppressed for recursive extension-error events to prevent loops.

- `:error` `string` (required)
- `:event` `keyword|string`
- `:owner` `keyword|string`
- `:type` `:extension-error` (required)

### `extension-loaded`
Emitted by the loader for each successfully loaded extension manifest.

- `:first-party?` `boolean`
- `:name` `string` (required)
- `:type` `:extension-loaded` (required)

### `info`
Transient informational message intended for the presenter status row or panel.

- `:info` `string`
- `:text` `string`
- `:type` `:info` (required)

### `llm-end`
Provider call completed (success or error). The :message field carries the canonical AssistantMessage.

- `:message` `AssistantMessage` (required)
- `:type` `:llm-end` (required)

### `llm-start`
Provider call beginning.

- `:model` `string`
- `:provider` `keyword`
- `:type` `:llm-start` (required)

### `message-appended`
Emitted by `fen.core.agent` immediately after `agent.messages` grows.

- `:agent` `Agent` (required)
- `:index` `number` (required) — 1-based index of the appended message.
- `:message` `Message` (required)
- `:type` `:message-appended` (required)

### `queued`
User-line queued while the agent is busy. Consumed by the agent on natural-stop.

- `:line` `string` (required)
- `:type` `:queued` (required)

### `redraw`
Presenter hint that a registered panel needs to be repainted.

- `:type` `:redraw` (required)

### `reinit-presenter`
Presenter signal that the UI should be torn down and re-initialized (used by /reload).

- `:type` `:reinit-presenter` (required)

### `reset-conversation`
Presenter signal that the active conversation should be cleared (used by /new).

- `:type` `:reset-conversation` (required)

### `set-status-info`
Presenter-level status hint. Owners post a transient status line; nil clears.

- `:info` `string|nil`
- `:type` `:set-status-info` (required)

### `start`
Provider stream opened. Marker event emitted before any block events.

- `:type` `:start` (required)

### `text-delta`
Provider stream: incremental text token within the open block.

- `:content-index` `number` (required)
- `:delta` `string` (required)
- `:type` `:text-delta` (required)

### `text-end`
Provider stream: TextContent block closed; full text supplied.

- `:content` `string` (required)
- `:content-index` `number` (required)
- `:type` `:text-end` (required)

### `text-start`
Provider stream: a TextContent block is starting.

- `:content-index` `number` (required) — Position within the assistant's content array.
- `:type` `:text-start` (required)

### `thinking-delta`
Provider stream: incremental reasoning token within the open block.

- `:content-index` `number` (required)
- `:delta` `string` (required)
- `:type` `:thinking-delta` (required)

### `thinking-end`
Provider stream: ThinkingContent block closed; full text supplied.

- `:content` `string` (required)
- `:content-index` `number` (required)
- `:type` `:thinking-end` (required)

### `thinking-start`
Provider stream: a ThinkingContent block is starting.

- `:content-index` `number` (required)
- `:type` `:thinking-start` (required)

### `tool-call`
Tool call about to execute. Carries the canonical ToolCall block.

- `:tool-call` `ToolCall` (required)
- `:type` `:tool-call` (required)

### `tool-call-delta`
Provider stream: incremental JSON-text fragment for the open ToolCall arguments. Some providers stream arguments token-by-token; consumers may concatenate.

- `:content-index` `number` (required)
- `:delta` `string` (required)
- `:type` `:tool-call-delta` (required)

### `tool-call-end`
Provider stream: ToolCall block closed; complete canonical ToolCall block supplied.

- `:content-index` `number` (required)
- `:tool-call` `ToolCall` (required)
- `:type` `:tool-call-end` (required)

### `tool-call-start`
Provider stream: a ToolCall block is starting; arguments not yet known.

- `:content-index` `number` (required)
- `:type` `:tool-call-start` (required)

### `tool-result`
Tool execution finished. Carries the canonical ToolResultMessage.

- `:result` `ToolResultMessage` (required)
- `:type` `:tool-result` (required)

### `user`
User-submitted line accepted by the presenter input layer. Distinct from :queued (which fires when the line is *queued* during a busy turn).

- `:line` `string` (required)
- `:type` `:user` (required)

## Canonical types

### `AgentContext`
Per-call payload handed to a provider's `:complete`.

- `:max-tokens` `number` (required)
- `:messages` `[Message]` (required)
- `:system-prompt` `string|nil`
- `:tools` `[Tool]` (required)

### `AgentTool`
Tool extended with execution metadata for the agent loop. Registered through `(api.register :tool ...)`.

- `:description` `string` (required)
- `:execute` `(args ?yield-fn) -> AgentToolResult` (required)
- `:label` `string` — UI label.
- `:name` `string` (required)
- `:parameters` `JSONSchema` (required)

### `AgentToolResult`
Outcome of a tool execution.

- `:content` `[TextContent]` (required)
- `:details` `any` — Opaque presenter payload (UI-only).
- `:is-error?` `boolean` (required)

### `AssistantMessage`
Single model response. Content is always an array, even when empty.

- `:api` `keyword` — :openai-completions | :openai-responses | :anthropic-messages | :openai-codex
- `:content` `[TextContent|ThinkingContent|ToolCall]` (required)
- `:error-message` `string` — Present only when stop-reason = :error.
- `:model` `string`
- `:provider` `keyword` — Registered provider :name (e.g. :openai, :anthropic).
- `:role` `:assistant` (required)
- `:stop-reason` `StopReason`
- `:timestamp` `number` (required)
- `:usage` `Usage`

### `Message`
Union of UserMessage, AssistantMessage, ToolResultMessage. Stored on `agent.messages` and passed to providers in `AgentContext.messages`.

Variants: `UserMessage` | `AssistantMessage` | `ToolResultMessage`

### `StopReason`
Why the assistant stopped producing output.

Values: `:stop` | `:length` | `:tool-use` | `:error` | `:aborted`

### `TextContent`
Plain visible text block.

- `:text` `string` (required)
- `:type` `:text` (required)

### `ThinkingContent`
Reasoning/extended-thinking block. Surfaces both Anthropic extended thinking and OpenAI reasoning items.

- `:redacted?` `boolean` — True when the provider redacted visible text.
- `:thinking` `string` (required)
- `:thinking-signature` `string` — Opaque echo signature; required for multi-turn extended thinking.
- `:type` `:thinking` (required)

### `Tool`
Provider-agnostic tool spec — what providers see in `AgentContext.tools`.

- `:description` `string` (required)
- `:name` `string` (required)
- `:parameters` `JSONSchema` (required) — {:type :object :properties {...} :required [...]}

### `ToolCall`
Assistant request to invoke a tool. Arguments are a parsed Lua table — providers JSON-decode wire arguments before constructing this block.

- `:arguments` `table` (required)
- `:id` `string` (required)
- `:name` `string` (required)
- `:type` `:tool-call` (required)

### `ToolResultMessage`
Result of a single tool call, carried back to the provider on the next turn.

- `:content` `[TextContent]` (required)
- `:details` `any` — Opaque presenter payload (UI-only).
- `:is-error?` `boolean` (required)
- `:role` `:tool-result` (required)
- `:timestamp` `number` (required)
- `:tool-call-id` `string` (required) — Matches the originating ToolCall.id.
- `:tool-name` `string` (required)

### `Usage`
Token usage counters returned by the provider (best-effort — providers fill what they can).

- `:cache-read` `number`
- `:cache-write` `number`
- `:input` `number`
- `:output` `number`
- `:total-tokens` `number`

### `UserMessage`
Single user turn. Content is either a plain string or an array of TextContent blocks.

- `:content` `string|[TextContent]` (required)
- `:role` `:user` (required)
- `:timestamp` `number` (required) — Milliseconds since epoch.

## Interfaces

### `auth-backend`
Required record shape for `(api.register :auth-backend ...)`.

Required methods: `:api-key`
Optional methods: `:login!`, `:logout!`

### `provider`
Required record shape for `(api.register :provider ...)`. See the :provider register-kind for field details.

Required methods: `:complete`, `:convert-messages`, `:convert-tools`, `:map-stop-reason`, `:parse-response`, `:build-body`

### `session-backend`
Required record shape for `(api.register :session-backend ...)`.

Required methods: `:open`, `:open-existing`, `:append`, `:close`, `:load`, `:find`, `:list`, `:latest`
