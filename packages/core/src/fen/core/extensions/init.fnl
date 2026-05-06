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
(set M.version state.version)
(set M.handlers state.handlers)
(set M.tools-extra state.tools-extra)
(set M.commands-extra state.commands-extra)
(set M.controls-extra state.controls-extra)
(set M.status-extra state.status-extra)
(set M.presenters state.presenters)
(set M.providers state.providers)
(set M.auth-backends state.auth-backends)
(set M.session-backends state.session-backends)
(set M.session state.session)
(set M.hooks state.hooks)
(set M.extensions state.extensions)
(set M.errors state.errors)
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
(fn M.list-errors [] (events.list-errors))
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

(fn M.active-presenter [] (register.active-presenter))
(fn M.init-active-presenter [ctx] (register.init-active-presenter ctx))
(fn M.shutdown-active-presenter [ctx] (register.shutdown-active-presenter ctx))
(fn M.run-active-presenter [ctx] (register.run-active-presenter ctx))
(fn M.build-ui-slot [] (register.build-ui-slot))
;; @doc fen.core.extensions.find-provider
;; kind: function
;; signature: (find-provider name) -> provider|nil
;; summary: Look up a provider by its registered :name.
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

(fn M.settings-api []
  (let [settings (require :fen.core.settings)]
    {:get (fn [?p] (settings.load ?p))
     :load! (fn [?p] (settings.load ?p))
     :set! (fn [s ?p] (settings.save! s ?p))
     :set-defaults! (fn [provider model ?p]
                      (settings.set-defaults! provider model ?p))}))

(fn M.models-api []
  (let [models (require :fen.core.llm.models)]
    {:list (fn [opts] (models.available-models opts))
     :find (fn [query available]
             (models.resolve-model-exact query (or available (models.available-models {}))))
     :resolve (fn [query available]
                (models.resolve-model query (or available (models.available-models {}))))
     :canonical-id (fn [model-ref] (models.canonical-model-id model-ref))}))

(fn M.agent-info [agent]
  (let [agent-mod (require :fen.core.agent)]
    {:safety-cap agent-mod.SAFETY-CAP
     :provider-name (?. agent :provider-name)
     :provider-api (?. agent :provider-api)
     :model (?. agent :model)
     :messages-count (length (or (?. agent :messages) []))}))

(fn M.types-api []
  (require :fen.core.types))

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
