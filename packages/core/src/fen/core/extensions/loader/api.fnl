;; Loader-owned extension API factory; extensions must not construct an api directly.
;; Reload contract: methods resolve module functions at call time, never pin function values.

(local state (require :fen.core.extensions.state))
(local events (require :fen.core.extensions.events))
(local logs (require :fen.core.extensions.logs))
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
    {:set-defaults! (fn [provider model ?p]
                      (settings.set-defaults! provider model ?p))
     :set-thinking-default! (fn [level ?p]
                              (settings.set-thinking-default! level ?p))}))

(fn models-api []
  (let [models (require :fen.core.llm.models)]
    {:list (fn [opts] (models.available-models opts))
     :inspect (fn [opts query] (models.inspect-providers opts query))
     :dynamic-cache (fn [] (models.dynamic-cache-snapshot))
     :resolve (fn [query available]
                (models.resolve-model query (or available (models.available-models {}))))
     :canonical-id (fn [model-ref] (models.canonical-model-id model-ref))}))

(fn register-allowed? [kind opts]
  (or opts.privileged?
      (register.public-register-kind? kind)
      (and opts.allowed-register-kinds
           (. opts.allowed-register-kinds kind))))

(fn assert-register-allowed! [kind opts owner]
  (when (not (register-allowed? kind opts))
    (error (.. "extension " (tostring owner)
               " cannot register privileged kind " (tostring kind)))))

(fn make-api [owner ?manifest ?opts]
  "Return the small stable api table handed to an extension's register function."
  (let [opts (or ?opts {})]
    (when (and owner ?manifest)
      (tset state.extensions owner
            {:manifest ?manifest :status :loaded :owner owner}))
    (let [api {:register (fn [kind spec]
                 (assert-register-allowed! kind opts owner)
                 (register.register kind spec owner))
     :on (fn [event-name handler] (events.on event-name handler owner))
     :emit (fn [ev] (events.emit ev))
     :log (fn [level value] (logs.record! owner level value))
     :prompt (fn [text-or-fn ?opts]
               (prompt-registry.contribute text-or-fn ?opts owner handle-result))
     :list (fn [kind]
             ;; Actions stay host-only until #181 supplies capability tiers.
             (when (and (= kind :actions) (not opts.privileged?))
               (error "action listing requires a privileged extension API"))
             (register.list kind))
     :introspect {:collect (fn [?owner ?ctx]
                             (register.collect-introspection ?owner ?ctx))}
     :commands {:dispatch (fn [line caller-state]
                            (command-registry.dispatch line caller-state))}
     :turn {:submit! (fn [caller-state text ?opts]
                       (let [submit (. (or caller-state {}) :submit-user-turn!)]
                         (if (= (type submit) :function)
                             (let [opts {}]
                               (each [k v (pairs (or ?opts {}))]
                                 (tset opts k v))
                               (when (= opts.emit-user? nil)
                                 (set opts.emit-user? true))
                               (submit text opts))
                             {:ok false
                              :error "turn submission is unavailable in this runtime"})))}
     :enqueue (fn [kind text ?opts]
                (if (not (or (= kind :steering) (= kind :follow-up)))
                    {:ok false :error (.. "unknown queue: " (tostring kind))}
                    (not= (type text) :string)
                    {:ok false :error "enqueue text must be a string"}
                    (= text "")
                    {:ok false :error "cannot enqueue an empty message"}
                    ;; Resolve the runtime bridge at call time so retained APIs follow reloads.
                    (let [enqueue state.enqueue!]
                      (if (= (type enqueue) :function)
                          (enqueue kind text ?opts)
                          {:ok false :error "no interactive runtime"}))))
     :auth {:find-backend (fn [name] (auth-backend-registry.find name))}
     :session {:active-backend (fn [] (session-backend-registry.active))
               :set-info! (fn [info ?handle]
                            (session-backend-registry.set-info! info ?handle))
               :info (fn [] (session-backend-registry.info))
               :append-state! (fn [value ?version]
                                (session-backend-registry.append-extension-state!
                                  owner value ?version))
               :latest-state (fn [?yield-fn ?accept]
                               (session-backend-registry.latest-extension-state
                                 owner ?yield-fn ?accept))}
     :diagnostics {:list-errors (fn [] (events.list-errors))
                   :error-log-path (fn [] (events.error-log-path))}
     :settings (settings-api)
     :models (models-api)
     :ui (presenter-registry.build-ui-slot)}]
      ;; Only privileged APIs get typed action discovery/invocation (see #181).
      (when opts.privileged?
        (tset api :actions
              {:list (fn [] (register.list-actions))
               :invoke (fn [action-owner name args ctx]
                         (register.invoke-action action-owner name args ctx))}))
      api)))

(tset M :make-api make-api)
(tset M :settings-api settings-api)
(tset M :models-api models-api)

M
