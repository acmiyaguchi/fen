;; Extension-facing API factory.
;;
;; Stable public extension API is the table returned by make-api:
;;   version, register, on, emit, prompt, list, ui, complete-once, settings,
;;   models, agent-info, types
;;
;; This module intentionally owns helper dependencies on agent/llm/models/
;; settings/types so fen.core.extensions can remain a registry/events/runtime
;; facade without pulling provider completion helpers into the core plumbing.
;;
;; Exported methods wrap underlying module tables in closures that resolve at
;; call time. This is the reload contract: when a registry/event module reloads,
;; already-created api tables pick up the new behavior through the mutated
;; module table rather than pinning old function values.

(local state (require :fen.core.extensions.state))
(local events (require :fen.core.extensions.events))
(local register (require :fen.core.extensions.register))

(local M {})

(fn provider-options [agent ?opts]
  (let [out {:api-key agent.api-key :max-tokens agent.max-tokens}]
    (each [k v (pairs (or agent.provider-options {}))]
      (tset out k v))
    (each [k v (pairs (or ?opts {}))]
      (tset out k v))
    out))

;; @doc fen.core.extensions.api.complete-once
;; kind: function
;; signature: (complete-once agent messages ?model ?opts ?on-event ?yield-fn) -> AssistantMessage
;; summary: Run one provider completion using an agent's provider/model/options while supplying explicit canonical messages and no tools.
;; tags: provider llm extensions api
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

;; @doc fen.core.extensions.api.settings-api
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

;; @doc fen.core.extensions.api.models-api
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

;; @doc fen.core.extensions.api.agent-info
;; kind: function
;; signature: (agent-info agent) -> table
;; summary: Return a compact, read-only snapshot of agent runtime metadata for extensions without exposing mutable agent internals.
;; tags: extensions agent introspection api
(fn M.agent-info [agent]
  (let [agent-mod (require :fen.core.agent)]
    {:safety-cap agent-mod.SAFETY-CAP
     :provider-name (?. agent :provider-name)
     :provider-api (?. agent :provider-api)
     :model (?. agent :model)
     :messages-count (length (or (?. agent :messages) []))}))

;; @doc fen.core.extensions.api.types-api
;; kind: function
;; signature: (types-api) -> table
;; summary: Return the canonical type constructor/extractor module exposed to extensions that need to build Message or ToolResult records.
;; tags: extensions types api
(fn M.types-api []
  (require :fen.core.types))

;; @doc fen.core.extensions.api.make-api
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
   :register (fn [kind spec] (register.register kind spec owner))
   :on (fn [event-name handler] (events.on event-name handler owner))
   :emit (fn [ev] (events.emit ev))
   :prompt (fn [text-or-fn ?opts]
             (register.contribute text-or-fn ?opts owner))
   :list (fn [kind] (register.list kind))
   :complete-once (fn [agent messages ?model ?opts ?on-event ?yield-fn]
                    (M.complete-once agent messages ?model ?opts ?on-event ?yield-fn))
   :settings (M.settings-api)
   :models (M.models-api)
   :agent-info (fn [agent] (M.agent-info agent))
   :types (M.types-api)
   :ui (register.build-ui-slot)})

M
