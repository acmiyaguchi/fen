;; Loader-owned extension API factory.
;;
;; Extensions receive the api table from the loader; they should not require
;; this module or construct an api directly. Keeping construction loader-owned
;; preserves owner identity and leaves room for public/privileged api splits.
;;
;; Methods wrap underlying module tables in closures that resolve at call time.
;; This is the reload contract: when a registry/event module reloads,
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

(fn settings-api []
  (let [settings (require :fen.core.settings)]
    {:load! (fn [?p] (settings.load ?p))
     :set-defaults! (fn [provider model ?p]
                      (settings.set-defaults! provider model ?p))}))

(fn models-api []
  (let [models (require :fen.core.llm.models)]
    {:list (fn [opts] (models.available-models opts))
     :resolve (fn [query available]
                (models.resolve-model query (or available (models.available-models {}))))
     :canonical-id (fn [model-ref] (models.canonical-model-id model-ref))}))

(fn make-api [owner ?manifest]
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
   :settings (settings-api)
   :models (models-api)
   :ui (presenter-registry.build-ui-slot)})

(tset M :make-api make-api)
(tset M :settings-api settings-api)
(tset M :models-api models-api)

M
