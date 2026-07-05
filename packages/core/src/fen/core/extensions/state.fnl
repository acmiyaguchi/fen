;; Persistent extension runtime state. Not reloadable.

;; @doc fen.core.extensions.state.version
;; kind: data
;; signature: number
;; summary: Schema/version marker for the persistent extension state table shared across reloadable extension modules.
;; tags: extensions state reload

;; @doc fen.core.extensions.state.handlers
;; kind: data
;; signature: table
;; summary: Event-bus handler buckets keyed by event name, preserving subscriptions across reloadable event-module updates.
;; tags: extensions state events

;; @doc fen.core.extensions.state.tools-extra
;; kind: data
;; signature: [AgentTool]
;; summary: Array registry of extension-contributed tools appended to the agent's base tool set each step.
;; tags: extensions state tools

;; @doc fen.core.extensions.state.commands-extra
;; kind: data
;; signature: table
;; summary: Singleton registry of slash-command contributions keyed by command name for dispatch and help introspection.
;; tags: extensions state commands

;; @doc fen.core.extensions.state.controls-extra
;; kind: data
;; signature: [Control]
;; summary: Array registry of presenter-neutral keyboard/control contributions exposed to active presenters.
;; tags: extensions state controls

;; @doc fen.core.extensions.state.status-extra
;; kind: data
;; signature: [StatusItem]
;; summary: Array registry of status-line contributors sorted by presenters into left/right status regions.
;; tags: extensions state status

;; @doc fen.core.extensions.state.panel-extra
;; kind: data
;; signature: [Panel]
;; summary: Array registry of non-modal panel contributions rendered by presenters that support panel regions.
;; tags: extensions state panels

;; @doc fen.core.extensions.state.presenters
;; kind: data
;; signature: [Presenter]
;; summary: Array registry of presenter contributions, including lifecycle callbacks and optional UI slot implementations.
;; tags: extensions state presenter

;; @doc fen.core.extensions.state.introspectors-extra
;; kind: data
;; signature: [Introspector]
;; summary: Array registry of extension-owned read-only snapshot providers exposed through agent_state, /extensions, and runtime diagnostics.
;; tags: extensions state introspection

;; @doc fen.core.extensions.state.providers
;; kind: data
;; signature: table
;; summary: Singleton registry of LLM provider contributions keyed by provider name for deterministic model dispatch.
;; tags: extensions state providers

;; @doc fen.core.extensions.state.auth-backends
;; kind: data
;; signature: table
;; summary: Singleton registry of auth backend contributions keyed by name for provider credential resolution.
;; tags: extensions state auth

;; @doc fen.core.extensions.state.session-backends
;; kind: data
;; signature: table
;; summary: Singleton registry of session persistence backend contributions keyed by backend name.
;; tags: extensions state session

;; @doc fen.core.extensions.state.session
;; kind: data
;; signature: table
;; summary: Active session backend selection and cached SessionInfo shared by session commands, tools, and backends.
;; tags: extensions state session

;; @doc fen.core.extensions.state.hooks
;; kind: data
;; signature: table
;; summary: Lifecycle hook registries, currently the before-tool hook array consulted before tool execution.
;; tags: extensions state hooks

;; @doc fen.core.extensions.state.input-handlers
;; kind: data
;; signature: [InputHandler]
;; summary: Ordered registry of non-slash input handlers consulted before user input starts a turn.
;; tags: extensions state input

;; @doc fen.core.extensions.state.prompt-fragments
;; kind: data
;; signature: [PromptFragment]
;; summary: Ordered system-prompt fragment registry rendered into the agent context before provider calls.
;; tags: extensions state prompt

;; @doc fen.core.extensions.state.prompt-next-seq
;; kind: data
;; signature: number
;; summary: Monotonic sequence counter used to keep prompt-fragment ordering stable when fragments share the same order.
;; tags: extensions state prompt

;; @doc fen.core.extensions.state.extensions
;; kind: data
;; signature: table
;; summary: Loader status records keyed by extension name for runtime docs, diagnostics, and extension-listing commands.
;; tags: extensions state loader

;; @doc fen.core.extensions.state.reload-fingerprints
;; kind: data
;; signature: table
;; summary: Cached file/module fingerprints that let extension reload report checked and changed modules across reloads.
;; tags: extensions state reload

;; @doc fen.core.extensions.state.runtime-info
;; kind: data
;; signature: table|nil
;; summary: Sanitized runtime/build metadata injected by fen.main and attached to durable diagnostics.
;; tags: extensions state diagnostics

;; @doc fen.core.extensions.state.errors
;; kind: data
;; signature: [ExtensionError]
;; summary: Bounded in-memory list of sanitized extension/event-bus errors for diagnostics and user-facing commands.
;; tags: extensions state diagnostics

;; @doc fen.core.extensions.state.error-log-path
;; kind: data
;; signature: string|nil
;; summary: Lazily initialized JSONL path where extension and event-bus errors are mirrored for postmortem inspection.
;; tags: extensions state diagnostics

;; @doc fen.core.extensions.state.ui
;; kind: data
;; signature: table
;; summary: Persistent presenter UI slot wrapper whose identity survives reload while active presenter behavior changes underneath.
;; tags: extensions state ui reload

{:version 1
 :handlers {}
 :tools-extra []
 :commands-extra {}
 :controls-extra []
 :status-extra []
 :panel-extra []
 :presenters []
 :introspectors-extra []
 :providers {}
 :auth-backends {}
 :session-backends {}
 :session {:active-name nil :backend nil :info nil}
 :hooks {:before-tool []}
 :input-handlers []
 :prompt-fragments []
 :prompt-next-seq 0
 :extensions {}
 :reload-fingerprints {}
 :runtime-info nil
 :errors []
 :error-log-path nil
 :ui {:slot nil}}
