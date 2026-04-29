;; Conversation/session lifecycle commands: /new, /reload, aliases.

(local extensions (require :core.extensions))
(local session-mod (require :core.session))

(local M {})

(fn register-new [api]
  (api.register :command
    {:name :new
     :order 10
     :description "Reset the current conversation and start a fresh session"
     :idle-only? true
     :handler (fn [_args state]
                (session-mod.close state.session)
                (state.loader.reload state.loader)
                (set state.agent
                     (state.make-agent-from-opts
                       state.opts state.on-event state.loader state.agent-extra))
                (set state.steering-queue [])
                (set state.follow-up-queue [])
                (when state.update-queue-status (state.update-queue-status))
                (set state.session (state.open-session state.opts))
                (set state.flush (state.make-flush state.agent state.session))
                (set state.agent.on-message-append
                     (fn [_message _agent] (state.flush)))
                ;; Tell the active presenter to clear its transcript and
                ;; refresh the model/provider readout. Routed through the
                ;; bus so this handler stays presenter-agnostic.
                (extensions.emit {:type :reset-conversation})
                (extensions.emit
                  {:type :set-status-info
                   :info {:provider state.opts.provider
                          :model state.agent.model}})
                (extensions.emit
                  {:type :assistant-text
                   :text "✓ New session started"}))}))

(fn format-extension-line [item]
  (let [changed (or item.changed 0)
        checked (or item.checked 0)
        status item.status]
    (if (not= status :loaded)
        (.. "    " (tostring item.name) " (failed: " (tostring status) ")")
        (.. "    " (tostring item.name) " (" (tostring changed)
            "/" (tostring checked) " changed)"))))

(fn format-reload-summary [core-summary ext-summary msg-count]
  (let [core (or core-summary {:reloaded 0 :changed 0 :failed 0})
        ext (or ext-summary {:loaded 0 :changed 0 :failed 0 :extensions []})
        title (if (or (> (or core.failed 0) 0)
                      (> (or ext.failed 0) 0))
                  "/reload (errors)"
                  "/reload")
        lines [(.. title
                   " core " (tostring core.changed) "/" (tostring core.reloaded)
                   " changed; ext " (tostring ext.changed) "/" (tostring ext.loaded)
                   " changed; msgs " (tostring msg-count))]]
    (when (> (length (or ext.extensions [])) 0)
      (table.insert lines "")
      (table.insert lines "extensions:")
      (each [_ item (ipairs ext.extensions)]
        (table.insert lines (format-extension-line item))))
    (table.concat lines "\n")))

(fn register-reload [api]
  (api.register :command
    {:name :reload
     :order 30
     :description "Hot-reload core modules (run `make build` first)"
     :idle-only? true
     :handler (fn [_args state]
                (let [(_n failures core-summary) (state.reload-modules)
                      ext-summary (when state.load-extensions
                                    (state.load-extensions state.opts
                                                           {:interactive? true
                                                            :reload? true}))
                      _ (set state.loader (state.resource-loader.make state.opts))
                      saved state.agent.messages
                      new-agent (state.make-agent-from-opts
                                  state.opts state.on-event state.loader
                                  state.agent-extra)]
                  ;; Reuse the messages table by reference so any code that still
                  ;; holds the old agent's messages table sees appended messages.
                  (set new-agent.messages saved)
                  (set new-agent.on-message-append
                       (fn [_message _agent] (state.flush)))
                  (set state.agent new-agent)
                  ;; Re-apply presenter runtime config (input mode, cached
                  ;; dims) — init! is idempotent so this is safe even if the
                  ;; presenter is already initialized.
                  (extensions.emit {:type :reinit-presenter})
                  (extensions.emit
                    {:type :assistant-text
                     :text (format-reload-summary core-summary ext-summary
                                                  (length saved))})
                  (each [_ f (ipairs failures)]
                    (extensions.emit {:type :error :error (.. "reload: " f)}))
                  ;; A reload often changes renderer/layout code; force a full
                  ;; repaint instead of trusting any cached front-buffer diff.
                  (extensions.emit {:type :redraw})))}))

(fn M.register [api]
  (register-new api)
  (api.register :command
    {:name :n
     :order 20
     :description "Alias for /new"
     :idle-only? true
     :handler (fn [args state]
                ;; Delegate to /new via the registry to avoid duplicating the
                ;; body. The dispatcher does not recurse for us so we look it up
                ;; ourselves — same handler, same semantics.
                ((. extensions.commands-extra :new :handler) args state))})
  (register-reload api)
  (api.register :command
    {:name :r
     :order 40
     :description "Alias for /reload"
     :idle-only? true
     :handler (fn [args state]
                ((. extensions.commands-extra :reload :handler) args state))}))

M
