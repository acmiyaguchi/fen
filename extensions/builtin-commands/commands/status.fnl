;; /status command: togglable panel showing model, provider, message count,
;; token usage, and session info.

(local extensions (require :fen.core.extensions))
(local util (require :fen.extensions.builtin_commands.util))
(local panel-state (require :fen.extensions.builtin_commands.state.status))

(local M {})

(fn format-auth [state]
  "Describe how the active provider is authenticating."
  (let [provider state.opts.provider]
    (if (= provider :openai-codex) "subscription (via pi)"
        (= provider :openai) "$OPENAI_API_KEY"
        (= provider :openai-responses) "$OPENAI_API_KEY"
        (= provider :anthropic) "$ANTHROPIC_API_KEY"
        (.. "custom (" (tostring provider) ")"))))

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

(fn status-rows [state]
  (let [agent state.agent
        usage (util.usage-totals agent.messages)
        approx (util.estimated-context-tokens agent)
        session (or (extensions.session-info) (?. state :session))
        session-path (?. session :path)
        session-id (?. session :id)
        session-backend (?. session :backend)]
    [(heading "Status")
     (dim (.. "  version:        " (util.runtime-version)))
     (dim (.. "  model:          " (tostring agent.model)))
     (dim (.. "  provider:       " (tostring agent.provider-name)))
     (dim (.. "  auth:           " (format-auth state)))
     (dim (.. "  messages:       " (tostring (length (or agent.messages [])))))
     (dim (.. "  approx context: ~" (tostring approx) " tokens"))
     (dim (.. "  reported usage: " (tostring usage.total-tokens) " tokens"))
     (dim (.. "    input:        " (tostring usage.input)))
     (dim (.. "    output:       " (tostring usage.output)))
     (dim (.. "    cache read:   " (tostring usage.cache-read)))
     (dim (.. "    cache write:  " (tostring usage.cache-write)))
     (dim (.. "  tokens:         " (util.format-token-summary usage approx)))
     (dim (.. "  reply cap:      " (tostring agent.max-tokens) " tokens"))
     (dim (.. "  session:        " (or session-path "disabled")))
     (dim (.. "  session id:     " (or session-id "disabled")))
     (dim (.. "  session backend: " (or session-backend "disabled")))]))

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

(fn panel-rows [w]
  ;; Throttle to 1 Hz; cache invalidates on width change.
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w))
      (let [content (if panel-state.run-state
                        (status-rows panel-state.run-state)
                        [(heading "Status") (dim "  (no run state)")])]
        (set panel-state.cached-rows (bordered-rows w content)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0))

(fn panel-spec []
  {:name :status
   :placement :above-input
   :order 40
   :height (fn [ctx]
             (if panel-state.visible?
                 (length (panel-rows (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if panel-state.visible?
                 (panel-rows (or (?. ctx :w) 80))
                 []))})

(fn handle-toggle []
  (if panel-state.visible?
      (do (set panel-state.visible? false)
          (invalidate-cache!)
          (extensions.emit {:type :info :text "status panel: off"}))
      (do
        ;; Close any other open panel — panels are mutually exclusive.
        (extensions.emit {:type :dismiss})
        (set panel-state.visible? true)
        (invalidate-cache!)
        (extensions.emit {:type :info :text "status panel: on"}))))

(fn M.register [api]
  (api.register :command
    {:name :status
     :order 10
     :description "Toggle the status panel (model, provider, tokens, session)"
     :handler (fn [_args state]
                (when state (set panel-state.run-state state))
                (handle-toggle))})
  (api.register :panel (panel-spec))
  (api.on :dismiss
    (fn [ev]
      (when panel-state.visible?
        (set panel-state.visible? false)
        (invalidate-cache!)
        (when ev.announce?
          (extensions.emit {:type :info :text "status panel: off"})))))
  (api.on :llm-end
    (fn [_ev] (invalidate-cache!))))

M
