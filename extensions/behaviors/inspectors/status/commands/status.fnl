;; /status command: togglable panel showing model, provider, message count,
;; token usage, and session info.

(local tokens (require :fen.util.tokens))
(local util (require :fen.extensions.status.util))
(local panel (require :fen.util.panel))
(local panel-state (require :fen.extensions.status.state.status))

(local M {})

(local dim panel.dim)
(local heading panel.heading)

(fn format-auth [state]
  "Describe how the active provider is authenticating."
  (let [provider state.opts.provider]
    (if (= provider :openai-codex) "subscription (oauth)"
        (= provider :openai) "$OPENAI_API_KEY"
        (= provider :openai-responses) "$OPENAI_API_KEY"
        (= provider :anthropic) "$ANTHROPIC_API_KEY"
        (.. "custom (" (tostring provider) ")"))))

(fn auth-detail-rows [api state]
  "If the active provider's auth-backend exposes :status-info, splat its
   {label, value} rows under the auth: line. Lets backends surface
   debugging info (e.g. relocated auth.json paths, env-var overrides)
   without /status hard-coding provider-specific knowledge."
  (let [provider state.opts.provider
        backend (and provider (api.auth.find-backend provider))
        info-fn (and backend backend.status-info)
        out []]
    (when info-fn
      (let [(ok? rows) (pcall info-fn)]
        (when (and ok? (= (type rows) :table))
          (each [_ row (ipairs rows)]
            (when (and row.label row.value)
              (table.insert out
                (dim (.. "    " row.label ": "
                         (string.rep " " (math.max 0 (- 9 (length row.label))))
                         row.value))))))))
    out))

(fn thinking-label [state agent]
  (let [opts (or (?. state :opts) {})]
    (or opts.thinking
        (and opts.reasoning-effort
             (.. "effort:" (tostring opts.reasoning-effort)))
        (and opts.thinking-budget
             (.. "budget:" (tostring opts.thinking-budget)))
        (and agent.thinking-status :custom)
        :off)))

(fn status-rows [api state]
  (let [agent state.agent
        usage (tokens.usage-totals agent.messages)
        context (tokens.context-token-info agent)
        context-n context.tokens
        context-prefix (if context.estimated? "~" "")
        session (or (api.session.info) (?. state :session))
        session-path (?. session :path)
        session-id (?. session :id)
        session-backend (?. session :backend)
        rows []]
    (table.insert rows (heading "Status"))
    (table.insert rows (dim (.. "  version:        " (util.runtime-version))))
    (table.insert rows (dim (.. "  model:          " (tostring agent.model))))
    (table.insert rows (dim (.. "  provider:       " (tostring agent.provider-name))))
    (table.insert rows (dim (.. "  thinking:       " (tostring (thinking-label state agent))
                                " (" (tostring (or agent.thinking-status "off")) ")")))
    (table.insert rows (dim (.. "  auth:           " (format-auth state))))
    (each [_ row (ipairs (auth-detail-rows api state))]
      (table.insert rows row))
    (table.insert rows (dim (.. "  messages:       " (tostring (length (or agent.messages []))))))
    (table.insert rows (dim (.. "  context:        " context-prefix
                                (tostring context-n) " tokens ("
                                (tostring context.source) ")")))
    (table.insert rows (dim (.. "  reported usage: " (tostring usage.total-tokens) " tokens")))
    (table.insert rows (dim (.. "    input:        " (tostring usage.input))))
    (table.insert rows (dim (.. "    output:       " (tostring usage.output))))
    (table.insert rows (dim (.. "    cache read:   " (tostring usage.cache-read))))
    (table.insert rows (dim (.. "    cache write:  " (tostring usage.cache-write))))
    (table.insert rows (dim (.. "  tokens:         "
                                (tokens.format-token-summary usage context-n
                                                             context.estimated?))))
    (let [last-turn (util.last-turn-latency agent.messages)]
      (when last-turn
        (table.insert rows (dim (.. "  last turn:      " last-turn)))))
    (table.insert rows (dim (.. "  reply cap:      " (tostring agent.max-tokens) " tokens")))
    (table.insert rows (dim (.. "  session:        " (or session-path "disabled"))))
    (table.insert rows (dim (.. "  session id:     " (or session-id "disabled"))))
    (table.insert rows (dim (.. "  session backend: " (or session-backend "disabled"))))
    rows))

(fn panel-rows [api w]
  ;; Throttle to 1 Hz; cache invalidates on width change.
  (panel.throttled-rows panel-state w "status"
    (fn []
      (if panel-state.run-state
          (status-rows api panel-state.run-state)
          [(heading "Status") (dim "  (no run state)")]))))

(fn panel-spec [api]
  {:name :status
   :placement :above-input
   :order 40
   :height (fn [ctx]
             (if panel-state.visible?
                 (length (panel-rows api (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if panel-state.visible?
                 (panel-rows api (or (?. ctx :w) 80))
                 []))})

(fn handle-toggle [api]
  (panel.toggle! panel-state api.emit "status"))

;; @doc fen.extensions.status.commands.status.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register the /status command and status panel for runtime, model, session, token, and extension diagnostics.
;; tags: commands status register
(fn M.register [api]
  (api.register :command
    {:name :status
     :order 10
     :description "Toggle the status panel (model, provider, tokens, session)"
     :handler (fn [_args state]
                (when state (set panel-state.run-state state))
                (handle-toggle api))})
  ;; @doc register-site:panel:status
  ;; summary: Runtime status details panel backing the /status command.
  ;; tags: panel status commands
  (api.register :panel (panel-spec api))

  (api.register :introspect
    {:name :panel
     :description "Current status panel cache and last captured run-state summary"
     :snapshot (fn [_]
                 (let [rs panel-state.run-state
                       agent (?. rs :agent)
                       session (or (api.session.info) (?. rs :session))]
                   {:visible? panel-state.visible?
                    :cached-w panel-state.cached-w
                    :cached-at panel-state.cached-at
                    :has-run-state? (not= rs nil)
                    :provider (?. agent :provider-name)
                    :model (?. agent :model)
                    :message-count (length (or (?. agent :messages) []))
                    :session-backend (?. session :backend)
                    :session-id (?. session :id)}))})

  (api.on :dismiss
    (fn [ev] (panel.dismissed! panel-state api.emit "status" ev)))
  (api.on :llm-end
    (fn [_ev] (panel.invalidate-cache! panel-state))))

M
