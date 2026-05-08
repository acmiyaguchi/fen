;; /status command: togglable panel showing model, provider, message count,
;; token usage, and session info.

(local util (require :fen.extensions.builtin_commands.util))
(local panel-state (require :fen.extensions.builtin_commands.state.status))

(local M {})

(fn format-auth [state]
  "Describe how the active provider is authenticating."
  (let [provider state.opts.provider]
    (if (= provider :openai-codex) "subscription (oauth)"
        (= provider :openai) "$OPENAI_API_KEY"
        (= provider :openai-responses) "$OPENAI_API_KEY"
        (= provider :anthropic) "$ANTHROPIC_API_KEY"
        (.. "custom (" (tostring provider) ")"))))

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

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

(fn status-rows [api state]
  (let [agent state.agent
        usage (util.usage-totals agent.messages)
        approx (util.estimated-context-tokens agent)
        session (or (api.session.info) (?. state :session))
        session-path (?. session :path)
        session-id (?. session :id)
        session-backend (?. session :backend)
        rows []]
    (table.insert rows (heading "Status"))
    (table.insert rows (dim (.. "  version:        " (util.runtime-version))))
    (table.insert rows (dim (.. "  model:          " (tostring agent.model))))
    (table.insert rows (dim (.. "  provider:       " (tostring agent.provider-name))))
    (table.insert rows (dim (.. "  auth:           " (format-auth state))))
    (each [_ row (ipairs (auth-detail-rows api state))]
      (table.insert rows row))
    (table.insert rows (dim (.. "  messages:       " (tostring (length (or agent.messages []))))))
    (table.insert rows (dim (.. "  approx context: ~" (tostring approx) " tokens")))
    (table.insert rows (dim (.. "  reported usage: " (tostring usage.total-tokens) " tokens")))
    (table.insert rows (dim (.. "    input:        " (tostring usage.input))))
    (table.insert rows (dim (.. "    output:       " (tostring usage.output))))
    (table.insert rows (dim (.. "    cache read:   " (tostring usage.cache-read))))
    (table.insert rows (dim (.. "    cache write:  " (tostring usage.cache-write))))
    (table.insert rows (dim (.. "  tokens:         " (util.format-token-summary usage approx))))
    (table.insert rows (dim (.. "  reply cap:      " (tostring agent.max-tokens) " tokens")))
    (table.insert rows (dim (.. "  session:        " (or session-path "disabled"))))
    (table.insert rows (dim (.. "  session id:     " (or session-id "disabled"))))
    (table.insert rows (dim (.. "  session backend: " (or session-backend "disabled"))))
    rows))

(fn box-top [w title]
  (let [head (.. "┌─ " title " ")
        head-cols (+ 4 (length title))
        fill-cols (math.max 0 (- w head-cols 1))]
    (.. head (string.rep "─" fill-cols) "┐")))

(fn box-bottom [w]
  (.. "└" (string.rep "─" (math.max 0 (- w 2))) "┘"))

(fn box-side [w text]
  (let [inner-w (math.max 0 (- w 4))
        text (or text "")
        n (length text)
        clipped (if (> n inner-w) (string.sub text 1 inner-w) text)
        pad (math.max 0 (- inner-w (length clipped)))]
    (.. "│ " clipped (string.rep " " pad) " │")))

(fn bordered-rows [w content]
  (let [out [{:text (box-top w "status") :style :dim}]]
    (each [_ row (ipairs content)]
      (table.insert out {:text (box-side w row.text) :style row.style}))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn panel-rows [api w]
  ;; Throttle to 1 Hz; cache invalidates on width change.
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w))
      (let [content (if panel-state.run-state
                        (status-rows api panel-state.run-state)
                        [(heading "Status") (dim "  (no run state)")])]
        (set panel-state.cached-rows (bordered-rows w content)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0))

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
  (if panel-state.visible?
      (do (set panel-state.visible? false)
          (invalidate-cache!)
          (api.emit {:type :info :text "status panel: off"}))
      (do
        ;; Close any other open panel — panels are mutually exclusive.
        (api.emit {:type :dismiss})
        (set panel-state.visible? true)
        (invalidate-cache!)
        (api.emit {:type :info :text "status panel: on"}))))

;; @doc fen.extensions.builtin_commands.commands.status.register
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
  (api.on :dismiss
    (fn [ev]
      (when panel-state.visible?
        (set panel-state.visible? false)
        (invalidate-cache!)
        (when ev.announce?
          (api.emit {:type :info :text "status panel: off"})))))
  (api.on :llm-end
    (fn [_ev] (invalidate-cache!))))

M
