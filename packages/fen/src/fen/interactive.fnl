;; Interactive presenter runtime for a fen process.
;;
;; main.fnl is the CLI entry: it parses args, resolves the provider, runs
;; one-shot subcommands, and then hands a validated opts table to `run!`. The
;; agent construction, cooperative turn loop, and presenter lifecycle that make
;; up an interactive session live here so main stays focused on process entry.
;;
;; Edits to the executing `run!` loop body itself still need a restart, since
;; that invocation is already on the stack when /reload swaps package.loaded.

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

(local M {})

(fn build-system-prompt [opts agent-tools]
  (system-prompt.build opts
                       (or agent-tools
                           (tool-registry.merged []))))

(fn thinking-status [provider-options]
  "Compact status-bar label for the materialized thinking/reasoning option."
  (if (?. provider-options :reasoning-effort)
      (.. "reason:" (tostring provider-options.reasoning-effort))
      (and (?. provider-options :thinking-budget)
           (> (or provider-options.thinking-budget 0) 0))
      (.. "think:" (tostring provider-options.thinking-budget))
      false))

(fn make-agent-from-opts [resolve-provider-config opts on-event extra]
  "Resolve the provider config (re-reads models.json each call so /reload
   picks up edits), then construct an Agent. The api-key, base-url, and
   compat fields ride through `:provider-options` into the provider's
   `complete`. Optional `extra` fields are forwarded to make-agent (used by
   interactive queue callbacks)."
  (let [cfg (resolve-provider-config opts)
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
    (let [agent-tools (tool-registry.merged [])
          spec {:provider-name cfg.provider-name
                :model cfg.model
                :system (build-system-prompt opts agent-tools)
                :api-key cfg.api-key
                :max-tokens opts.max-tokens
                :tools agent-tools
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

;; In-process /reload of core/provider/util modules is owned by
;; fen.core.extensions.loader.reload: the module set is derived from
;; package.loaded (every fen.* module except fen.extensions.*, which reload
;; through their manifests, and the persistent-identity modules).
(fn reload-core-modules! [?yield]
  (let [reload-loader (require :fen.core.extensions.loader.reload)]
    (reload-loader.reload-core! ?yield)))

(fn err-first-line [s]
  (let [text (tostring (or s ""))
        i (string.find text "\n" 1 true)]
    (if i (string.sub text 1 (- i 1)) text)))

(fn submit-user-turn! [state line ?opts]
  "Small public extension boundary for submitting a normal user turn."
  (turn-submit.submit! state line ?opts agent-mod.step events.emit))

;; @doc fen.interactive.run!
;; kind: function
;; signature: (run! opts resolve-provider-config) -> nil
;; summary: Build the agent, session, and run-state, then drive the active presenter's turn loop until shutdown or exit.
;; tags: runtime presenter agent lifecycle
(fn M.run! [opts resolve-provider-config]
  ;; Load bundled local extensions and any external extensions. The active
  ;; presenter registers itself through core.extensions, so main does not
  ;; need to know whether it is TUI, print, REPL, RPC, etc.; presenter-specific
  ;; lifecycle stays inside the extension.
  (extension-loader.load! opts {:interactive? true})
  (models-mod.register-providers!)
  (let [reload-loader (require :fen.core.extensions.loader.reload)]
    (reload-loader.snapshot-core!))
  (let [on-event (fn [ev] (events.emit ev))
        _state-box {:state nil}
        ;; make-agent-from-opts binds the provider resolver passed from main so
        ;; run-state and reloadable command handlers keep the (opts on-event
        ;; extra) signature they expect.
        make-agent (fn [o oe ex] (make-agent-from-opts resolve-provider-config o oe ex))
        ;; Queue state and drain policy live in the steering extension
        ;; (fen.extensions.steering.service); main only wires the agent callbacks and
        ;; folds queue counts into the status refresh. The callbacks resolve
        ;; through the module table at call time, so they stay reload-safe.
        steering (require :fen.extensions.steering.service)
        update-queue-status! (fn []
                               (let [st _state-box.state]
                                 (when st
                                   (let [info (steering.queue-info)]
                                     (set info.approx-context
                                          (token-util.estimated-context-tokens
                                            st.agent))
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
        ;; Mutable container so reloadable command handlers can swap the agent
        ;; record after /reload or replace the session after /new while the
        ;; on-submit closure keeps a live view. The named run-state module owns
        ;; the table shape and helper closures; this loop owns the presenter
        ;; loop that mutates busy/turn/cancel fields.
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
                 :submit-user-turn! submit-user-turn!})
        is-busy? (fn [] state.busy?)
        request-cancel (fn []
                         (when state.busy?
                           (set state.cancel-requested? true)))
        ;; Non-slash input flows through the ordered input-handler pipeline
        ;; (fen.core.extensions.input). The steering extension
        ;; registers the default/fallback handler at order 1000; other
        ;; extensions can transform or consume input before it. Queueing
        ;; handlers apply and announce their own effect; main only acts on
        ;; the :start / :error / :continue orchestration decisions.
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
                              ;; :continue means no handler resolved the input;
                              ;; fall back to starting a turn with the
                              ;; (possibly transformed) text.
                              (= action.action :continue)
                              (submit-user-turn! state
                                                 (or (?. action :input :text)
                                                     line))
                              ;; :queued / :consumed / :ignore -> no-op here.
                              nil))))
        on-tick (fn []
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
                        ;; The agent flushes each message as it appends it;
                        ;; this final call is kept as a harmless safety net
                        ;; for older/reloaded agents without the hook.
                        (state.flush)
                        (turn-lifecycle.emit-complete! state ok? value)))))]
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
    ;; Populate presenter status through the bus so the presenter is the
    ;; only thing that touches its own status state. The TUI subscriber
    ;; tolerates being called before/after init.
    (events.emit
      {:type :set-status-info
       :info {:provider opts.provider :model agent.model
              :thinking-status agent.thinking-status
              :steering-queued 0 :follow-up-queued 0
              :approx-context (token-util.estimated-context-tokens agent)}})
    (let [presenter-ctx {:state state
                         :on-submit on-submit
                         :on-tick on-tick
                         :request-cancel request-cancel
                         :is-busy? is-busy?
                         ;; Diagnostic hook: presenters that want to dump
                         ;; the in-flight agent coroutine on a stall can
                         ;; read it through this thunk without coupling
                         ;; to main's state shape.
                         :get-turn (fn [] state.turn)}
          (ok? err) (xpcall
                      #(let [(run-ok? run-err)
                             (presenter-registry.run-active-presenter presenter-ctx)]
                         (when (not run-ok?)
                           (error run-err)))
                      debug.traceback)
          (shutdown-ok? shutdown-err)
          (presenter-registry.shutdown-active-presenter presenter-ctx)]
      (when (not shutdown-ok?)
        (io.stderr:write (.. "presenter shutdown failed: "
                            (tostring shutdown-err) "\n"))
        ;; Defensive: if the presenter slot was lost (e.g. a botched
        ;; reload) the TUI's own shutdown never runs, leaving termbox2
        ;; holding the terminal in raw/no-echo mode. Force the teardown
        ;; here so the user's shell stays usable.
        (let [(ok-state? tui-state) (pcall require :fen.extensions.tui.state)
              (ok-tb? termbox2) (pcall require :termbox2)
              (ok-sink? log-sink) (pcall require :fen.util.log_sink)]
          (when (and ok-state? ok-tb? tui-state.tb-initialized?)
            (pcall (fn [] (termbox2.shutdown)))
            (set tui-state.tb-initialized? false)
            (when ok-sink? (pcall log-sink.close!)))))
      (session-lifecycle.close! state.session-backend state.session)
      (emit-agent-shutdown state.agent (if ok? :normal :crashed) (when (not ok?) err))
      (session-lifecycle.uninstall!)
      (when (not ok?)
        (io.stderr:write (.. "presenter crashed: " (tostring err) "\n"))
        (os.exit 1)))))

M
