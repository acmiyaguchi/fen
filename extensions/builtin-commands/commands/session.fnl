;; Conversation/session lifecycle commands: /new, /reload, aliases.
;;
;; /sessions and bare /resume open an fzf-style overlay over recent
;; sessions; /resume <target> keeps the existing find-by-id/path/index
;; path so scripts and muscle memory still work.

(local extensions (require :fen.core.extensions))
(local path-util (require :fen.util.path))

(local M {})

(fn trim [s]
  (or (string.match (or s "") "^%s*(.-)%s*$") ""))

(fn compact-time [ts]
  (let [(date hour minute) (string.match (or ts "") "^(%d%d%d%d%-%d%d%-%d%d)T(%d%d)%-(%d%d)")]
    (if date
        (.. date " " hour ":" minute)
        (or ts "unknown-time"))))

(fn compact-id [id]
  (let [s (or id "unknown-id")]
    (if (> (length s) 8)
        (string.sub s 1 8)
        s)))

(fn compact-title [title]
  (let [s (or title "untitled")]
    (if (> (length s) 56)
        (.. (string.sub s 1 53) "...")
        s)))

(fn message-count-label [n]
  (.. (tostring (or n 0)) " msgs"))

(fn format-session-line [rec]
  (.. (compact-time rec.timestamp)
      "  " (message-count-label rec.message-count)
      "  " (compact-id rec.id)
      "  " (compact-title rec.title)))

(fn install-agent-messages! [agent msgs]
  (set agent.messages [])
  (each [_ m (ipairs msgs)]
    (table.insert agent.messages m)))

(fn reset-queues! [state]
  (set state.steering-queue [])
  (set state.follow-up-queue [])
  (when state.update-queue-status (state.update-queue-status)))

(fn content-text [content]
  (if (= (type content) :string)
      content
      (= (type content) :table)
      (let [parts []]
        (each [_ block (ipairs content)]
          (when (and (= (?. block :type) :text) block.text)
            (table.insert parts block.text)))
        (table.concat parts ""))
      ""))

(fn replay-assistant-message! [msg]
  (var last-visible nil)
  (each [i block (ipairs (or msg.content []))]
    (when (or (and (= block.type :thinking) (not= (or block.thinking "") ""))
              (and (= block.type :text) (not= (or block.text "") "")))
      (set last-visible i)))
  (each [i block (ipairs (or msg.content []))]
    (if (= block.type :thinking)
        (when (not= (or block.thinking "") "")
          (extensions.emit {:type :assistant-thinking
                            :text block.thinking
                            :final? (= i last-visible)
                            :spacer-after? (< i last-visible)}))
        (= block.type :text)
        (when (not= (or block.text "") "")
          (extensions.emit {:type :assistant-text
                            :text block.text
                            :final? (= i last-visible)}))
        (= block.type :tool-call)
        (extensions.emit {:type :tool-call
                          :name block.name
                          :arguments block.arguments
                          :id block.id}))))

(fn replay-history! [msgs]
  (each [_ msg (ipairs (or msgs []))]
    (if (= msg.role :user)
        (extensions.emit {:type :user :text (content-text msg.content)})
        (= msg.role :assistant)
        (replay-assistant-message! msg)
        (= msg.role :tool-result)
        (extensions.emit {:type :tool-result
                          :name msg.tool-name
                          :id msg.tool-call-id
                          :result {:content msg.content
                                   :details msg.details
                                   :is-error? msg.is-error?}}))))

(fn resume-session! [state target]
  (let [cwd (path-util.cwd)
        p (and state.find-session (state.find-session cwd target))]
    (if (not p)
        (extensions.emit {:type :error
                          :error (.. "session not found: " (or target "latest"))})
        (let [msgs (or (and state.load-session (state.load-session p)) [])
              new-session (if state.opts.no-session?
                              nil
                              (and state.open-existing-session
                                   (state.open-existing-session p)))]
          (when (and (not state.opts.no-session?) (not new-session))
            (error (.. "could not open session for append: " p)))
          (when state.close-session (state.close-session state.session))
          (set state.agent
               (state.make-agent-from-opts
                 state.opts state.on-event state.agent-extra))
          (install-agent-messages! state.agent msgs)
          (reset-queues! state)
          (set state.session new-session)
          (extensions.set-session-info!
            (and state.session-info (state.session-info state.session)))
          (set state.flush (state.make-flush state.agent state.session (length msgs)))
          (when state.update-queue-status (state.update-queue-status))
          (extensions.emit {:type :reset-conversation})
          (replay-history! msgs)
          (extensions.emit
            {:type :set-status-info
             :info {:provider state.opts.provider
                    :model state.agent.model}})
          (extensions.emit
            {:type :info
             :text (.. "✓ Resumed session with "
                       (tostring (length msgs)) " messages")})))))

(fn build-session-choices [sessions]
  (let [out []]
    (each [_ rec (ipairs sessions)]
      (table.insert out
                    {:label (format-session-line rec)
                     :value rec
                     :description (or rec.title "")}))
    out))

(fn pick-session! [state]
  (let [cwd (path-util.cwd)
        sessions (if state.list-sessions (state.list-sessions cwd 50) [])]
    (if (= (length sessions) 0)
        (extensions.emit
          {:type :info :text "no sessions for this cwd"})
        (let [ui (extensions.build-ui-slot)
              picked (ui.select {:label "resume session"
                                 :choices (build-session-choices sessions)})]
          (when picked
            (let [rec (or picked.value picked)]
              (when rec
                (resume-session! state (or rec.path rec.id rec)))))))))

(fn register-new [api]
  (api.register :command
    {:name :new
     :order 10
     :description "Reset the current conversation and start a fresh session"
     :idle-only? true
     :handler (fn [_args state]
                (when state.close-session (state.close-session state.session))
                (set state.agent
                     (state.make-agent-from-opts
                       state.opts state.on-event state.agent-extra))
                (set state.steering-queue [])
                (set state.follow-up-queue [])
                (when state.update-queue-status (state.update-queue-status))
                (set state.session (state.open-session state.opts))
                (extensions.set-session-info!
                  (and state.session-info (state.session-info state.session)))
                (set state.flush (state.make-flush state.agent state.session))
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
     :description "Hot-reload core modules and source overlays"
     :idle-only? true
     :handler (fn [_args state]
                (let [(_n failures core-summary) (state.reload-modules)
                      ext-summary (when state.load-extensions
                                    (state.load-extensions state.opts
                                                           {:interactive? true
                                                            :reload? true}))
                      _models-count (when state.reload-model-providers
                                      (state.reload-model-providers))
                      _session-backend (set state.session-backend
                                            (extensions.active-session-backend))
                      saved state.agent.messages
                      new-agent (state.make-agent-from-opts
                                  state.opts state.on-event state.agent-extra)]
                  (set new-agent.messages saved)
                  (set state.agent new-agent)
                  (when state.update-queue-status (state.update-queue-status))
                  (extensions.emit {:type :reinit-presenter})
                  (extensions.emit
                    {:type :assistant-text
                     :text (format-reload-summary core-summary ext-summary
                                                  (length saved))})
                  (each [_ f (ipairs failures)]
                    (extensions.emit {:type :error :error (.. "reload: " f)}))
                  (extensions.emit {:type :redraw})))}))

;; @doc fen.extensions.builtin_commands.commands.session.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register conversation/session lifecycle commands including /new, /reload, /sessions, and /resume aliases.
;; tags: commands session register
(fn M.register [api]
  (register-new api)
  (api.register :command
    {:name :n
     :order 20
     :description "Alias for /new"
     :idle-only? true
     :handler (fn [args state]
                (extensions.dispatch-command (.. "/new " (or args "")) state))})
  (api.register :command
    {:name :sessions
     :order 25
     :description "Pick a recent session to resume (overlay)"
     :idle-only? true
     :handler (fn [_args state] (pick-session! state))})
  (api.register :command
    {:name :resume
     :order 26
     :description "Resume a session (overlay if no arg; id/prefix/path/index if given)"
     :idle-only? true
     :handler (fn [args state]
                (let [target (trim args)]
                  (if (= target "")
                      (pick-session! state)
                      (resume-session! state target))))})
  (register-reload api)
  (api.register :command
    {:name :r
     :order 40
     :description "Alias for /reload"
     :idle-only? true
     :handler (fn [args state]
                (extensions.dispatch-command (.. "/reload " (or args "")) state))}))

M
