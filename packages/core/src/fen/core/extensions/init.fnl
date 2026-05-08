;; Extension-facing API facade.
;;
;; Stable public extension API is only the table returned by make-api:
;;   version, register, on, emit, prompt, list, ui, complete-once, settings,
;;   models, agent-info, types
;;
;; The other exports on this module are core runtime plumbing for main.fnl,
;; tests, and bundled first-party extensions. They are intentionally available
;; in-process but are not part of the third-party extension contract.
;;
;; All exported methods wrap the underlying sub-module function in a closure
;; that resolves through the sub-module table at call time. This is the
;; reload contract: when a sub-module reloads, prior captures of its
;; functions stay valid because every call goes through the (mutated)
;; module table.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))
(local register (require :fen.core.extensions.register))

(local M {})

;; State table re-exports for tests/introspection. Identity lives in
;; core.extensions.state and survives reloads of this facade.

;; @doc fen.core.extensions.version
;; kind: data
;; signature: number
;; summary: Extension registry schema version re-exported for tests and runtime introspection.
;; tags: extensions state registry
(set M.version state.version)

;; @doc fen.core.extensions.handlers
;; kind: data
;; signature: table
;; summary: Persistent event-handler buckets keyed by event type, re-exported for diagnostics and tests.
;; tags: extensions state events
(set M.handlers state.handlers)

;; @doc fen.core.extensions.tools-extra
;; kind: data
;; signature: [Tool]
;; summary: Persistent first-party and extension tool contributions appended to base agent tools.
;; tags: extensions state tools
(set M.tools-extra state.tools-extra)

;; @doc fen.core.extensions.commands-extra
;; kind: data
;; signature: [Command]
;; summary: Persistent registered slash-command contributions sorted and dispatched by the extension registry.
;; tags: extensions state commands
(set M.commands-extra state.commands-extra)

;; @doc fen.core.extensions.controls-extra
;; kind: data
;; signature: [Control]
;; summary: Persistent registered UI control contributions exposed to presenters and docs.
;; tags: extensions state controls ui
(set M.controls-extra state.controls-extra)

;; @doc fen.core.extensions.status-extra
;; kind: data
;; signature: [StatusItem]
;; summary: Persistent registered status-line contributions rendered by presenter status bars.
;; tags: extensions state status ui
(set M.status-extra state.status-extra)

;; @doc fen.core.extensions.presenters
;; kind: data
;; signature: [Presenter]
;; summary: Persistent registered presenter records, including TUI, stdio, web, and print implementations.
;; tags: extensions state presenters ui
(set M.presenters state.presenters)

;; @doc fen.core.extensions.providers
;; kind: data
;; signature: [Provider]
;; summary: Persistent registered LLM provider records looked up by name or API family.
;; tags: extensions state providers llm
(set M.providers state.providers)

;; @doc fen.core.extensions.auth-backends
;; kind: data
;; signature: [AuthBackend]
;; summary: Persistent registered auth backend records used by provider login and token refresh flows.
;; tags: extensions state auth providers
(set M.auth-backends state.auth-backends)

;; @doc fen.core.extensions.session-backends
;; kind: data
;; signature: [SessionBackend]
;; summary: Persistent registered session backend records used for JSONL persistence and resume.
;; tags: extensions state sessions
(set M.session-backends state.session-backends)

;; @doc fen.core.extensions.session
;; kind: data
;; signature: table
;; summary: Persistent active session state shared by the extension facade and session registry helpers.
;; tags: extensions state sessions
(set M.session state.session)

;; @doc fen.core.extensions.hooks
;; kind: data
;; signature: table
;; summary: Persistent before-tool and after-tool hook buckets keyed by hook name.
;; tags: extensions state hooks tools
(set M.hooks state.hooks)

;; @doc fen.core.extensions.extensions
;; kind: data
;; signature: [ExtensionInfo]
;; summary: Persistent loaded-extension metadata records reported by /extensions and runtime docs.
;; tags: extensions state loader introspection
(set M.extensions state.extensions)

;; @doc fen.core.extensions.errors
;; kind: data
;; signature: [ExtensionError]
;; summary: Persistent bounded extension error records captured by isolated event handlers.
;; tags: extensions state errors diagnostics
(set M.errors state.errors)

;; @doc fen.core.extensions.ui
;; kind: data
;; signature: table
;; summary: Persistent presenter UI slot containing notify, prompt, and select hooks exposed through extension APIs.
;; tags: extensions state ui presenters
(set M.ui state.ui)

;; Runtime wrappers — each call resolves through the sub-module table at
;; call time so reloading events / register sub-modules picks up the new
;; behavior even for callers that captured a reference to one of these
;; methods before the reload.

;; @doc fen.core.extensions.emit
;; kind: function
;; signature: (emit ev) -> nil
;; summary: Dispatch ev to handlers[ev.type] and the `:*` wildcard bucket.
;; tags: events bus
(fn M.emit [ev] (events.emit ev))

;; @doc fen.core.extensions.list-errors
;; kind: function
;; signature: (list-errors) -> [ExtensionError]
;; summary: Return the in-memory extension error records captured by the event bus for diagnostics and `/extension errors` style inspection.
;; tags: extensions events diagnostics
(fn M.list-errors [] (events.list-errors))

;; @doc fen.core.extensions.error-log-path
;; kind: function
;; signature: (error-log-path) -> string|nil
;; summary: Return the path where extension handler failures are mirrored, or nil until the error log has been initialized.
;; tags: extensions events diagnostics
(fn M.error-log-path [] (events.error-log-path))

;; @doc fen.core.extensions.on
;; kind: function
;; signature: (on event-name handler ?owner) -> unsubscribe-fn
;; summary: Subscribe handler to event-name. Owner-tagged handlers are removed by unregister-by-owner.
;; tags: events bus subscribe
(fn M.on [event-name handler ?owner] (events.on event-name handler ?owner))

;; @doc fen.core.extensions.register
;; kind: function
;; signature: (register kind spec owner) -> {:kind :name :owner :unregister}
;; summary: Register a contribution under the given kind. See contracts.register-kinds for the kind list.
;; tags: extensions register
;; see-also: register-kind:tool, register-kind:command, register-kind:provider
(fn M.register [kind spec owner] (register.register kind spec owner))

;; @doc fen.core.extensions.dispatch-command
;; kind: function
;; signature: (dispatch-command line caller-state) -> nil
;; summary: Look up and pcall-isolate a registered slash command. Emits :error on failure.
;; tags: commands
(fn M.dispatch-command [line caller-state]
  (register.dispatch-command line caller-state))

;; @doc fen.core.extensions.prompt
;; kind: function
;; signature: (prompt text-or-fn ?opts owner) -> {:kind :name :owner :unregister}
;; summary: Contribute a system-prompt fragment. text-or-fn is a string or a (ctx)->string function. opts may carry :id :title :description :order.
;; tags: prompt extensions
(fn M.prompt [text-or-fn ?opts owner]
  (register.contribute text-or-fn ?opts owner))

;; @doc fen.core.extensions.render-prompt
;; kind: function
;; signature: (render-prompt ctx) -> string
;; summary: Render all registered prompt fragments into one string, joined by blank lines, ordered by :order then registration order.
;; tags: prompt
(fn M.render-prompt [ctx] (register.render-prompt ctx))

;; @doc fen.core.extensions.merged-tools
;; kind: function
;; signature: (merged-tools base) -> [Tool]
;; summary: Append registered :tool contributions to base, preserving order. Duplicates last-wins on tool name.
;; tags: tools
(fn M.merged-tools [base] (register.merged-tools base))

;; @doc fen.core.extensions.run-before-tool
;; kind: function
;; signature: (run-before-tool tool-name args ctx) -> any
;; summary: Run all :before-tool hooks against the pending call. Hooks may inspect or replace args.
;; tags: hooks tools
(fn M.run-before-tool [tool-name args ctx]
  (register.run-before-tool tool-name args ctx))

;; @doc fen.core.extensions.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Drop every contribution and event handler tagged with owner. Used by the loader and by reloadable modules at the top of their bodies.
;; tags: extensions reload
(fn M.unregister-by-owner [owner] (register.unregister-by-owner owner))

;; @doc fen.core.extensions.list
;; kind: function
;; signature: (list kind) -> [record]
;; summary: List registered contributions of a given kind. kind is one of :tools :commands :controls :status :panels :presenters :providers :auth-backends :session-backends :extensions :event-handlers :prompt-fragments.
;; tags: extensions introspection
(fn M.list [kind] (register.list kind))

;; @doc fen.core.extensions.active-presenter
;; kind: function
;; signature: (active-presenter) -> presenter|nil
;; summary: Return the presenter selected for this run, or nil before presenter initialization has chosen one.
;; tags: presenter ui extensions
(fn M.active-presenter [] (register.active-presenter))

;; @doc fen.core.extensions.init-active-presenter
;; kind: function
;; signature: (init-active-presenter ctx) -> any
;; summary: Invoke the active presenter's optional :init callback with the runtime context, preserving presenter-specific return behavior.
;; tags: presenter ui lifecycle
(fn M.init-active-presenter [ctx] (register.init-active-presenter ctx))

;; @doc fen.core.extensions.shutdown-active-presenter
;; kind: function
;; signature: (shutdown-active-presenter ctx) -> any
;; summary: Invoke the active presenter's optional :shutdown callback during teardown so terminal/UI resources can be released.
;; tags: presenter ui lifecycle
(fn M.shutdown-active-presenter [ctx] (register.shutdown-active-presenter ctx))

;; @doc fen.core.extensions.run-active-presenter
;; kind: function
;; signature: (run-active-presenter ctx) -> any
;; summary: Run the selected presenter's required :run callback, which owns the interactive input/output loop for the process.
;; tags: presenter ui lifecycle
(fn M.run-active-presenter [ctx] (register.run-active-presenter ctx))

;; @doc fen.core.extensions.build-ui-slot
;; kind: function
;; signature: (build-ui-slot) -> table
;; summary: Return the persistent presenter UI slot shared with extension APIs so reloads keep panel/status state identity stable.
;; tags: presenter ui reload
(fn M.build-ui-slot [] (register.build-ui-slot))
;; @doc fen.core.extensions.find-provider
;; kind: function
;; signature: (find-provider name) -> provider|nil
;; summary: Look up a provider implementation by its registered :name in the extension registry.
;; tags: provider
(fn M.find-provider [name] (register.find-provider name))

;; @doc fen.core.extensions.find-provider-by-api
;; kind: function
;; signature: (find-provider-by-api api) -> provider|nil
;; summary: Find the first provider whose :api matches. Many providers can share an :api family.
;; tags: provider
(fn M.find-provider-by-api [api] (register.find-provider-by-api api))

;; @doc fen.core.extensions.list-providers-by-api
;; kind: function
;; signature: (list-providers-by-api api) -> [provider]
;; summary: All providers registered for the given :api family.
;; tags: provider
(fn M.list-providers-by-api [api] (register.list-providers-by-api api))

;; @doc fen.core.extensions.find-auth-backend
;; kind: function
;; signature: (find-auth-backend name) -> auth-backend|nil
;; summary: Look up an auth backend by its registered :name.
;; tags: auth provider
(fn M.find-auth-backend [name] (register.find-auth-backend name))

;; @doc fen.core.extensions.find-session-backend
;; kind: function
;; signature: (find-session-backend name) -> backend|nil
;; summary: Look up a session backend by its registered :name.
;; tags: session
(fn M.find-session-backend [name] (register.find-session-backend name))

;; @doc fen.core.extensions.set-active-session-backend!
;; kind: function
;; signature: (set-active-session-backend! name) -> nil
;; summary: Activate a registered session backend by name. Subsequent appends route through it.
;; tags: session
(fn M.set-active-session-backend! [name]
  (register.set-active-session-backend! name))

;; @doc fen.core.extensions.active-session-backend
;; kind: function
;; signature: (active-session-backend) -> backend|nil
;; summary: Return the active session backend record, or nil if --no-session is in effect.
;; tags: session
(fn M.active-session-backend [] (register.active-session-backend))

;; @doc fen.core.extensions.set-session-info!
;; kind: function
;; signature: (set-session-info! info) -> nil
;; summary: Cache the SessionInfo returned by a backend's :start! for later inspection.
;; tags: session
(fn M.set-session-info! [info] (register.set-session-info! info))

;; @doc fen.core.extensions.session-info
;; kind: function
;; signature: (session-info) -> SessionInfo|nil
;; summary: Return the session info cached by the active backend.
;; tags: session
(fn M.session-info [] (register.session-info))

(fn provider-options [agent ?opts]
  (let [out {:api-key agent.api-key :max-tokens agent.max-tokens}]
    (each [k v (pairs (or agent.provider-options {}))]
      (tset out k v))
    (each [k v (pairs (or ?opts {}))]
      (tset out k v))
    out))

;; @doc fen.core.extensions.complete-once
;; kind: function
;; signature: (complete-once agent messages ?model ?opts ?on-event ?yield-fn) -> AssistantMessage
;; summary: Run one provider completion using an agent's provider/model/options while supplying explicit canonical messages and no tools.
;; tags: provider llm extensions
(fn M.complete-once [agent messages ?model ?opts ?on-event ?yield-fn]
  "Run one provider completion using an agent's provider configuration. The
   caller supplies canonical messages; tools are intentionally empty for this
   one-shot helper."
  (let [llm (require :fen.core.llm)
        context {:system-prompt agent.system-prompt
                 :messages (agent.convert-to-llm (or messages []))
                 :tools []}]
    (llm.complete agent.provider-name (or ?model agent.model) context
                  (provider-options agent ?opts) ?on-event ?yield-fn)))

;; @doc fen.core.extensions.settings-api
;; kind: function
;; signature: (settings-api) -> SettingsApi
;; summary: Build the settings helper table exposed to extensions for loading and updating user defaults in settings.json.
;; tags: extensions settings api
(fn M.settings-api []
  (let [settings (require :fen.core.settings)]
    {:get (fn [?p] (settings.load ?p))
     :load! (fn [?p] (settings.load ?p))
     :set! (fn [s ?p] (settings.save! s ?p))
     :set-defaults! (fn [provider model ?p]
                      (settings.set-defaults! provider model ?p))}))

;; @doc fen.core.extensions.models-api
;; kind: function
;; signature: (models-api) -> ModelsApi
;; summary: Build the model-selection helper table exposed to extensions for listing, resolving, and canonicalizing model refs.
;; tags: extensions models api
(fn M.models-api []
  (let [models (require :fen.core.llm.models)]
    {:list (fn [opts] (models.available-models opts))
     :find (fn [query available]
             (models.resolve-model-exact query (or available (models.available-models {}))))
     :resolve (fn [query available]
                (models.resolve-model query (or available (models.available-models {}))))
     :canonical-id (fn [model-ref] (models.canonical-model-id model-ref))}))

;; @doc fen.core.extensions.agent-info
;; kind: function
;; signature: (agent-info agent) -> table
;; summary: Return a compact, read-only snapshot of agent runtime metadata for extensions without exposing mutable agent internals.
;; tags: extensions agent introspection
(fn M.agent-info [agent]
  (let [agent-mod (require :fen.core.agent)]
    {:safety-cap agent-mod.SAFETY-CAP
     :provider-name (?. agent :provider-name)
     :provider-api (?. agent :provider-api)
     :model (?. agent :model)
     :messages-count (length (or (?. agent :messages) []))}))

;; @doc fen.core.extensions.types-api
;; kind: function
;; signature: (types-api) -> table
;; summary: Return the canonical type constructor/extractor module exposed to extensions that need to build Message or ToolResult records.
;; tags: extensions types api
(fn M.types-api []
  (require :fen.core.types))

;; @doc fen.core.extensions.record-extension!
;; kind: function
;; signature: (record-extension! name rec) -> rec
;; summary: Store loader status for one extension so runtime docs, diagnostics, and extension-listing commands can inspect it.
;; tags: extensions loader introspection
(fn M.record-extension! [name rec]
  "Record loader status for introspection."
  (tset state.extensions name rec)
  rec)

;; @doc fen.core.extensions.reset!
;; kind: function
;; signature: (reset!) -> nil
;; summary: Wipe all registries in place so identity references (e.g. presenter ui-slot) survive reset.
;; tags: extensions test reload
(fn M.reset! []
  "Wipe all registries IN PLACE so identity references survive reset."
  (util.clear-table state.handlers)
  (util.clear-table state.tools-extra)
  (util.clear-table state.commands-extra)
  (util.clear-table state.controls-extra)
  (util.clear-table state.status-extra)
  (util.clear-table state.panel-extra)
  (util.clear-table state.presenters)
  (when (= state.providers nil) (set state.providers {}))
  (util.clear-table state.providers)
  (when (= state.auth-backends nil) (set state.auth-backends {}))
  (util.clear-table state.auth-backends)
  (when (= state.session-backends nil) (set state.session-backends {}))
  (util.clear-table state.session-backends)
  (when (= state.session nil)
    (set state.session {:active-name nil :backend nil :info nil}))
  (set state.session.active-name nil)
  (set state.session.backend nil)
  (set state.session.info nil)
  (util.clear-table state.hooks.before-tool)
  (util.clear-table state.prompt-fragments)
  (set state.prompt-next-seq 0)
  (util.clear-table state.extensions)
  (when (= state.errors nil) (set state.errors []))
  (util.clear-table state.errors)
  (set state.error-log-path nil)
  (set state.ui.slot nil)
  nil)

;; @doc fen.core.extensions.make-api
;; kind: function
;; signature: (make-api owner ?manifest) -> ExtensionApi
;; summary: Return the small stable api table handed to an extension. Carries owner-scoped wrappers around register / on / emit / prompt / list, plus the version field and a presenter ui-slot. This is the public extension contract.
;; tags: extensions api reload
;; see-also: register-kind:tool, register-kind:command, register-kind:provider
(fn M.make-api [owner ?manifest]
  "Return the small stable api table handed to an extension's register function."
  (when (and owner ?manifest)
    (tset state.extensions owner
          {:manifest ?manifest :status :loaded :owner owner}))
  {:version state.version
   :register (fn [kind spec] (M.register kind spec owner))
   :on (fn [event-name handler] (M.on event-name handler owner))
   :emit (fn [ev] (M.emit ev))
   :prompt (fn [text-or-fn ?opts]
             (M.prompt text-or-fn ?opts owner))
   :list (fn [kind] (M.list kind))
   :complete-once (fn [agent messages ?model ?opts ?on-event ?yield-fn]
                    (M.complete-once agent messages ?model ?opts ?on-event ?yield-fn))
   :settings (M.settings-api)
   :models (M.models-api)
   :agent-info (fn [agent] (M.agent-info agent))
   :types (M.types-api)
   :ui (M.build-ui-slot)})

M
