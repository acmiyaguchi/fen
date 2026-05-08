;; Extension-facing API factory.
;;
;; Stable public extension API is the table returned by make-api:
;;   register, on, emit, prompt, list, ui, settings, models
;;
;; This module intentionally owns helper dependencies on models/settings so
;; runtime callers can depend on exact registry/event leaf modules without
;; pulling model-selection helpers into core plumbing.
;;
;; Exported methods wrap underlying module tables in closures that resolve at
;; call time. This is the reload contract: when a registry/event module reloads,
;; already-created api tables pick up the new behavior through the mutated
;; module table rather than pinning old function values.

(local state (require :fen.core.extensions.state))
(local events (require :fen.core.extensions.events))
(local register (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local presenter-registry (require :fen.core.extensions.register.presenter))
(local auth-backend-registry (require :fen.core.extensions.register.auth_backend))
(local session-backend-registry (require :fen.core.extensions.register.session_backend))

(local M {})

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

;; @doc fen.core.extensions.api.settings-api
;; kind: function
;; signature: (settings-api) -> SettingsApi
;; summary: Build the settings helper table exposed to extensions for loading and updating user defaults in settings.json.
;; tags: extensions settings api
(fn M.settings-api []
  (let [settings (require :fen.core.settings)]
    {:load! (fn [?p] (settings.load ?p))
     :set-defaults! (fn [provider model ?p]
                      (settings.set-defaults! provider model ?p))}))

;; @doc fen.core.extensions.api.models-api
;; kind: function
;; signature: (models-api) -> ModelsApi
;; summary: Build the model-selection helper table exposed to extensions for listing, resolving, and canonicalizing model refs.
;; tags: extensions models api
(fn M.models-api []
  (let [models (require :fen.core.llm.models)]
    {:list (fn [opts] (models.available-models opts))
     :resolve (fn [query available]
                (models.resolve-model query (or available (models.available-models {}))))
     :canonical-id (fn [model-ref] (models.canonical-model-id model-ref))}))

;; @doc fen.core.extensions.api.make-api
;; kind: function
;; signature: (make-api owner ?manifest) -> ExtensionApi
;; summary: Return the small stable api table handed to an extension. Carries owner-scoped wrappers around register / on / emit / prompt / list, plus provider/settings helpers and a presenter ui-slot. This is the public extension contract.
;; tags: extensions api reload
;; see-also: register-kind:tool, register-kind:command, register-kind:provider
(fn M.make-api [owner ?manifest]
  "Return the small stable api table handed to an extension's register function."
  (when (and owner ?manifest)
    (tset state.extensions owner
          {:manifest ?manifest :status :loaded :owner owner}))
  {:register (fn [kind spec] (register.register kind spec owner))
   :on (fn [event-name handler] (events.on event-name handler owner))
   :emit (fn [ev] (events.emit ev))
   :prompt (fn [text-or-fn ?opts]
             (prompt-registry.contribute text-or-fn ?opts owner handle-result))
   :list (fn [kind] (register.list kind))
   :commands {:dispatch (fn [line caller-state]
                          (command-registry.dispatch line caller-state))}
   :auth {:find-backend (fn [name] (auth-backend-registry.find name))}
   :session {:active-backend (fn [] (session-backend-registry.active))
             :set-info! (fn [info] (session-backend-registry.set-info! info))
             :info (fn [] (session-backend-registry.info))}
   :diagnostics {:list-errors (fn [] (events.list-errors))
                 :error-log-path (fn [] (events.error-log-path))}
   :settings (M.settings-api)
   :models (M.models-api)
   :ui (presenter-registry.build-ui-slot)})

M
