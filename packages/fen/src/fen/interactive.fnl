;; Interactive presenter runtime: agent construction, turn loop, presenter lifecycle.
;; Edits to the executing `run!` loop body need a restart; that invocation is already on the stack when /reload swaps package.loaded.

(local agent-mod (require :fen.core.agent))
(local system-prompt (require :fen.core.prompt))
(local thinking (require :fen.core.thinking))
(local tool-registry (require :fen.core.extensions.register.tool))
(local command-registry (require :fen.core.extensions.register.command))
(local input-pipeline (require :fen.core.extensions.input))
(local presenter-registry (require :fen.core.extensions.register.presenter))
(local extension-loader (require :fen.core.extensions.loader))
(local events (require :fen.core.extensions.events))
(local models-mod (require :fen.core.llm.models))
(local token-util (require :fen.util.tokens))
(local run-state (require :fen.run_state))
(local session-lifecycle (require :fen.session_lifecycle))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local turn-submit (require :fen.turn_submit))
(local tool-policy (require :fen.tool_policy))
(local reload-request (require :fen.reload_request))

(local M {})

(fn build-system-prompt [opts agent-tools]
  (system-prompt.build opts
                       (or agent-tools
                           (tool-registry.merged []))))

(fn context-status-info [agent]
  (let [context (token-util.context-token-info agent)]
    {:approx-context context.tokens
     :context-estimated? context.estimated?
     :context-source context.source}))

(fn thinking-status [provider-options]
  "Compact status-bar label for the materialized thinking/reasoning option."
  (if (?. provider-options :reasoning-effort)
      (.. "reason:" (tostring provider-options.reasoning-effort))
      (and (?. provider-options :thinking-budget)
           (> (or provider-options.thinking-budget 0) 0))
      (.. "think:" (tostring provider-options.thinking-budget))
      false))

(fn activate-tools! [active-tool-names tools]
  "Mark every supplied tool active so its schema appears on the next request."
  (each [_ tool (ipairs (or tools []))]
    (tset active-tool-names (tostring tool.name) true)))

(fn pin-tools! [active-tool-names pinned agent-tools]
  "Mark configured pinned tools active so their schemas appear on the first
   request without a preliminary tool_search. Only names that resolve to a
   registered tool are pinned; always-visible tools are harmless no-ops."
  (when (and pinned (> (length pinned) 0))
    (let [known {}]
      (each [_ t (ipairs (or agent-tools []))]
        (tset known (tostring t.name) true))
      (each [_ name (ipairs pinned)]
        (when (. known (tostring name))
          (tset active-tool-names (tostring name) true))))))

(fn M.make-agent-from-opts [resolve-provider-config opts on-event extra]
  "Resolve the provider config (re-reads models.json each call so /reload
   picks up edits), then construct an Agent. The api-key, base-url, and
   compat fields ride through `:provider-options` into the provider's
   `complete`. Optional `extra` fields are forwarded to make-agent (used by
   interactive queue callbacks)."
  (let [cfg (resolve-provider-config opts)
        active-tool-names (or opts.active-tool-names {})
        _active (set opts.active-tool-names active-tool-names)
        provider-options (thinking.level->provider-options opts.thinking cfg.api)]
    (when cfg.base-url (set provider-options.base-url cfg.base-url))
    (when cfg.compat (set provider-options.compat cfg.compat))
    (when cfg.creds (set provider-options.creds cfg.creds))
    (when opts.thinking-budget
      (set provider-options.thinking-budget opts.thinking-budget))
    (when opts.reasoning-effort
      (set provider-options.reasoning-effort opts.reasoning-effort))
    (when opts.retry-max-attempts
      (set provider-options.retry-max-attempts opts.retry-max-attempts))
    (let [registered-tools (tool-registry.merged [])
          (agent-tools policy-error) (tool-policy.apply opts registered-tools)
          (restriction restriction-error) (tool-policy.restriction-info opts registered-tools)
          _policy (when policy-error (error policy-error))
          _restriction (when restriction-error (error restriction-error))
          ;; An explicit allowlist also exposes every selected tool, including search-gated ones.
          _allowlist (when opts.tools (activate-tools! active-tool-names agent-tools))
          _pin (pin-tools! active-tool-names opts.pinned-tools agent-tools)
          spec {:provider-name cfg.provider-name
                :model cfg.model
                :system (build-system-prompt opts agent-tools)
                :api-key cfg.api-key
                :max-tokens opts.max-tokens
                :tools agent-tools
                :tool-restriction restriction
                :active-tool-names active-tool-names
                : provider-options
                :thinking-status (thinking-status provider-options)
                : on-event}]
      (each [k v (pairs (or extra {}))]
        (tset spec k v))
      (agent-mod.make-agent spec))))

(fn emit-agent-started [agent opts]
  "Emit sanitized process/run startup metadata. Avoid passing raw opts because
   it may contain internal or sensitive fields."
  (events.emit {:type :agent-started
                :agent agent
                :provider opts.provider
                :model agent.model
                :cwd (session-lifecycle.cwd)}))

(fn emit-agent-shutdown [agent reason ?error]
  (events.emit {:type :agent-shutdown
                :agent agent
                :reason (or reason :normal)
                :error ?error}))

;; Core /reload is owned by fen.core.extensions.loader.reload; module set derives from package.loaded minus fen.extensions.* and persistent-identity modules.
(fn reload-core-modules! [?yield ?opts]
  (let [reload-loader (require :fen.core.extensions.loader.reload)]
    (reload-loader.reload-core! ?yield ?opts)))

(fn err-first-line [s]
  (let [text (tostring (or s ""))
        i (string.find text "\n" 1 true)]
    (if i (string.sub text 1 (- i 1)) text)))

(fn submit-agent-turn! [turn-state line ?opts ?emit]
  "Run any in-process agent state through the shared turn submitter."
  (turn-submit.submit! turn-state line ?opts agent-mod.step
                       (or ?emit events.emit)))

(fn submit-user-turn! [state line ?opts]
  "Small public extension boundary for submitting a normal user turn."
  (submit-agent-turn! state line ?opts events.emit))

;; @doc fen.interactive.run!
;; kind: function
;; signature: (run! opts resolve-provider-config) -> exit-code|nil
;; summary: Build the agent, session, and run-state, drive the active presenter's turn loop, and return its exit code (nil for presenters that exit through their own lifecycle).
;; tags: runtime presenter agent lifecycle
(fn M.run! [opts resolve-provider-config]
  (extension-loader.load! opts {:interactive? true})
  (models-mod.register-providers!)
  (let [(_filtered policy-error)
        (tool-policy.apply opts (tool-registry.merged []))]
    (when policy-error
      (io.stderr:write (.. policy-error "\n"))
      (os.exit 2)))
  (let [reload-loader (require :fen.core.extensions.loader.reload)]
    (reload-loader.snapshot-core!))
  (let [on-event (fn [ev] (events.emit ev))
        _state-box {:state nil}
        make-agent (fn [o oe ex] (M.make-agent-from-opts resolve-provider-config o oe ex))
        ;; Callbacks resolve through the steering module table at call time, so they stay reload-safe.
        steering (require :fen.extensions.steering.service)
        update-queue-status! (fn []
                               (let [st _state-box.state]
                                 (when st
                                   (let [info (steering.queue-info)]
                                     (each [k v (pairs (context-status-info st.agent))]
                                       (tset info k v))
                                     (events.emit {:type :set-status-info
                                                   :info info})))))
        agent-extra {:get-steering (fn [] (steering.get-steering))
                     :get-follow-up (fn [] (steering.get-follow-up))
                     :tool-context
                     (fn [_agent]
                       {:state _state-box.state})}
        backend (session-lifecycle.resolve-backend opts)
        agent (make-agent opts on-event agent-extra)
        (session replayed) (session-lifecycle.start! opts agent backend)
        flush (session-lifecycle.make-flush backend agent session replayed)
        ;; Mutable container so reloadable handlers can swap agent/session after /reload or /new while on-submit keeps a live view.
        state (run-state.make
                {: opts : on-event : agent : session : flush
                 :session-backend backend
                 :make-agent-from-opts make-agent
                 :state-box _state-box
                 : session-lifecycle
                 : extension-loader
                 :models-mod models-mod
                 :reload-modules reload-core-modules!
                 :agent-extra agent-extra
                 :update-queue-status update-queue-status!
                 :submit-agent-turn! submit-agent-turn!
                 :submit-user-turn! submit-user-turn!})
        _steering-runtime
        (steering.install-runtime!
          {:is-idle? (fn [] (and (not state.busy?) (not state.turn)))
           :start-follow-up! (fn [text] (submit-user-turn! state text))})
        is-busy? (fn [] state.busy?)
        request-cancel (fn []
                         (when state.busy?
                           (set state.cancel-requested? true)))
        on-submit (fn [line]
                    (if (= (string.sub line 1 1) "/")
                        (command-registry.dispatch line state)
                        (let [action (input-pipeline.handle
                                       {:kind :user-input :text line}
                                       {:busy? state.busy? :state state})]
                          (if (= action.action :start)
                              (submit-user-turn! state action.text)
                              (= action.action :error)
                              (events.emit {:type :error
                                            :error (or action.error
                                                       "input rejected")})
                              (= action.action :continue)
                              (submit-user-turn! state
                                                 (or (?. action :input :text)
                                                     line))
                              nil))))
        on-tick (fn []
                  (events.emit {:type :runtime-tick
                                :busy? (not (not state.busy?))
                                :agent state.agent})
                  (when state.turn
                    (let [(ok? value) (coroutine.resume state.turn)]
                      (when (not ok?)
                        (events.emit
                          {:type :error
                           :error (.. "agent task: " (err-first-line value))
                           :traceback (debug.traceback state.turn (tostring value))}))
                      (when (or (not ok?)
                                (= (coroutine.status state.turn) :dead))
                        (if ok?
                            (set state.turn-result value)
                            (set state.turn-error value))
                        (set state.busy? false)
                        (set state.turn nil)
                        (set state.cancel-requested? false)
                        (turn-lifecycle.emit-complete! state ok? value))))
                  ;; Reload requests stay queued until the turn coroutine is gone, so modules never swap during a stream or tool call.
                  (when (and (not state.busy?) (not state.turn))
                    (reload-request.drain!
                      state
                      (fn [request]
                        (events.emit {:type :info
                                      :text (.. "reload request> executing "
                                                 (tostring request.scope)
                                                 ": " request.reason)})
                        (command-registry.dispatch
                          (reload-request.command-line request) state)))
                    ;; Idle follow-ups start only after active-turn and reload work reach this boundary.
                    (steering.start-idle-follow-up!)))]
    (session-lifecycle.install! state)
    (when (> replayed 0) (state.flush))
    (let [(init-ok? init-err)
          (presenter-registry.init-active-presenter {:state state})]
      (when (not init-ok?)
        (session-lifecycle.close! state.session-backend state.session)
        (emit-agent-shutdown state.agent :crashed init-err)
        (session-lifecycle.uninstall!)
        (io.stderr:write (.. "presenter init failed: "
                            (tostring init-err) "\n"))
        (os.exit 1)))
    (emit-agent-started state.agent opts)
    (let [info {:provider opts.provider :model agent.model
                :thinking-status agent.thinking-status
                :steering-queued 0 :follow-up-queued 0}]
      (each [k v (pairs (context-status-info agent))]
        (tset info k v))
      (events.emit {:type :set-status-info :info info}))
    (let [presenter-ctx {:state state
                         :on-submit on-submit
                         :on-tick on-tick
                         :request-cancel request-cancel
                         :is-busy? is-busy?
                         :get-turn (fn [] state.turn)}
          (ok? run-result) (xpcall
                      #(let [(run-ok? run-result)
                             (presenter-registry.run-active-presenter presenter-ctx)]
                         (if run-ok?
                             run-result
                             (error run-result)))
                      debug.traceback)
          (shutdown-ok? shutdown-err)
          (presenter-registry.shutdown-active-presenter presenter-ctx)]
      (when (not shutdown-ok?)
        (io.stderr:write (.. "presenter shutdown failed: "
                            (tostring shutdown-err) "\n"))
        ;; If the presenter slot was lost (e.g. botched reload), force termbox2 teardown so the terminal leaves raw/no-echo mode.
        (let [(ok-state? tui-state) (pcall require :fen.extensions.tui.state)
              (ok-tb? termbox2) (pcall require :termbox2)
              (ok-sink? log-sink) (pcall require :fen.util.log_sink)]
          (when (and ok-state? ok-tb? tui-state.tb-initialized?)
            (pcall (fn [] (termbox2.shutdown)))
            (set tui-state.tb-initialized? false)
            (when ok-sink? (pcall log-sink.close!)))))
      (steering.install-runtime! nil)
      (session-lifecycle.close! state.session-backend state.session)
      (emit-agent-shutdown state.agent (if ok? :normal :crashed) (when (not ok?) run-result))
      (session-lifecycle.uninstall!)
      (when (not ok?)
        (io.stderr:write (.. "presenter crashed: " (tostring run-result) "\n"))
        (os.exit 1))
      run-result)))

;; @doc fen.interactive.submit-agent-turn!
;; kind: function
;; signature: (submit-agent-turn! state line ?opts ?emit) -> table
;; summary: Submit a turn through the current interactive turn helper.
;; tags: runtime presenter agent turn
(set M.submit-agent-turn! submit-agent-turn!)

;; @doc fen.interactive.pin-tools!
;; kind: function
;; signature: (pin-tools! active-tool-names pinned agent-tools) -> nil
;; summary: Seed the active-tool-names set with configured pinned tools that resolve to a registered tool, so their schemas appear without a preliminary tool_search.
;; tags: interactive tools pinned exposure
(set M.pin-tools! pin-tools!)

M
