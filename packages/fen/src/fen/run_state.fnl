;; Interactive runtime state construction.
;;
;; The presenter loop owns orchestration, but the mutable run-state record is a
;; shared boundary for slash commands and first-party helpers. Keep its shape in
;; one named module instead of assembling the table inline in main.fnl.

(local M {})

(fn current-state [state-box]
  (or state-box.state
      (error "run state is not installed")))

(fn call-backend [state-box method ...]
  (let [st (current-state state-box)
        backend st.session-backend
        f (and backend (. backend method))]
    (when f
      (f ...))))

;; @doc fen.run_state.make
;; kind: function
;; signature: (make cfg) -> RunState
;; summary: Build the interactive runtime state table and install it in cfg.state-box for reload-safe closures.
;; tags: runtime state presenter sessions
(fn M.make [cfg]
  (let [state-box (or cfg.state-box {:state nil})
        session-lifecycle cfg.session-lifecycle
        extension-loader cfg.extension-loader
        models-mod cfg.models-mod
        state {:opts cfg.opts
               :on-event cfg.on-event
               :agent cfg.agent
               :session cfg.session
               :flush cfg.flush
               :session-backend cfg.session-backend
               :make-agent-from-opts cfg.make-agent-from-opts
               :open-session (fn [opts]
                               (let [st (current-state state-box)]
                                 (session-lifecycle.open opts st.session-backend)))
               :open-existing-session (fn [ref ?yield-fn]
                                        (call-backend state-box :open-existing
                                                      ref ?yield-fn))
               :close-session (fn [session]
                                (let [st (current-state state-box)]
                                  (session-lifecycle.close! st.session-backend
                                                            session)))
               :make-flush (fn [agent session ?last-saved]
                             (let [st (current-state state-box)]
                               (session-lifecycle.make-flush st.session-backend
                                                            agent session
                                                            ?last-saved)))
               :load-session (fn [ref ?yield-fn]
                               (call-backend state-box :load ref ?yield-fn))
               :find-session (fn [cwd target ?yield-fn]
                               (call-backend state-box :find cwd target
                                             ?yield-fn))
               :list-sessions (fn [cwd limit ?yield-fn]
                                (or (call-backend state-box :list cwd limit
                                                  ?yield-fn)
                                    []))
               :session-info (fn [session]
                               (let [st (current-state state-box)]
                                 (session-lifecycle.backend-info
                                   st.session-backend session)))
               :reload-modules cfg.reload-modules
               :load-extensions
               (fn [opts mode] (extension-loader.load! opts mode))
               :reload-extension
               (fn [name] (extension-loader.reload-extension! name))
               :reload-model-providers
               (fn [] (models-mod.register-providers!))
               :agent-extra cfg.agent-extra
               :update-queue-status cfg.update-queue-status
               :busy? false
               :turn-id 0
               :turn nil
               :turn-result nil
               :turn-error nil
               :cancel-requested? false
               :submit-user-turn! nil}]
    (set state.submit-user-turn!
         (fn [line ?opts]
           (cfg.submit-user-turn! state line ?opts)))
    (set state-box.state state)
    state))

M
