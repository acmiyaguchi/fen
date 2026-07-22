;; Conversation/session lifecycle commands: /new, /reload, aliases.
;;
;; /sessions and bare /resume open an fzf-style overlay over recent
;; sessions; /resume <target> keeps the existing find-by-id/path/index
;; path so scripts and muscle memory still work.

(local path-util (require :fen.util.path))
(local coroutines (require :fen.util.coroutines))
(local types (require :fen.core.types))
(local steering (require :fen.extensions.steering.service))
(local log (require :fen.util.log))
(local process (require :fen.util.process))

(local M {})

(local trim (. (require :fen.util.text) :trim))

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
  (steering.clear-queues!)
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

(fn replay-assistant-message! [api msg]
  (var last-visible nil)
  (each [i block (ipairs (or msg.content []))]
    (when (or (and (= block.type :thinking) (not= (or block.thinking "") ""))
              (and (= block.type :text) (not= (or block.text "") "")))
      (set last-visible i)))
  (each [i block (ipairs (or msg.content []))]
    (if (= block.type :thinking)
        (when (not= (or block.thinking "") "")
          (api.emit {:type :assistant-thinking
                            :text block.thinking
                            :final? (= i last-visible)
                            :spacer-after? (< i last-visible)}))
        (= block.type :text)
        (when (not= (or block.text "") "")
          (api.emit {:type :assistant-text
                            :text block.text
                            :final? (= i last-visible)}))
        (= block.type :tool-call)
        (api.emit {:type :tool-call
                          :name block.name
                          :arguments block.arguments
                          :id block.id}))))

(fn replay-history! [api msgs]
  (each [_ msg (ipairs (or msgs []))]
    (if (= msg.role :user)
        (api.emit {:type :user :text (content-text msg.content)})
        (= msg.role :assistant)
        (replay-assistant-message! api msg)
        (= msg.role :tool-result)
        (api.emit {:type :tool-result
                          :name msg.tool-name
                          :id msg.tool-call-id
                          :result {:content msg.content
                                   :details msg.details
                                   :is-error? msg.is-error?}}))))

(fn resume-session! [api state target]
  (let [cwd (path-util.cwd)
        p (and state.find-session (state.find-session cwd target))]
    (if (not p)
        (api.emit {:type :error
                          :error (.. "session not found: " (or target "latest"))})
        (let [msgs (or (and state.load-session (state.load-session p)) [])
              new-session (if state.opts.no-session?
                              nil
                              (and state.open-existing-session
                                   (state.open-existing-session p)))]
          (when (and (not state.opts.no-session?) (not new-session))
            (error (.. "could not open session for append: " p)))
          (when state.close-session (state.close-session state.session))
          ;; A continued session is a conversation boundary for ephemeral tool
          ;; activation; tool_search selections are intentionally not persisted.
          (set state.opts.active-tool-names {})
          (set state.agent
               (state.make-agent-from-opts
                 state.opts state.on-event state.agent-extra))
          (install-agent-messages! state.agent msgs)
          (reset-queues! state)
          (set state.session new-session)
          (api.session.set-info!
            (and state.session-info (state.session-info state.session))
            state.session)
          (set state.flush (state.make-flush state.agent state.session (length msgs)))
          (when state.update-queue-status (state.update-queue-status))
          (api.emit {:type :reset-conversation})
          (replay-history! api msgs)
          (api.emit
            {:type :set-status-info
             :info {:provider state.opts.provider
                    :model state.agent.model
                    :thinking-status state.agent.thinking-status}})
          (api.emit
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

(fn pick-session! [api state]
  (let [cwd (path-util.cwd)
        sessions (if state.list-sessions (state.list-sessions cwd 50) [])]
    (if (= (length sessions) 0)
        (api.emit
          {:type :info :text "no sessions for this cwd"})
        (let [ui api.ui
              picked (ui.select {:label "resume session"
                                 :choices (build-session-choices sessions)})]
          (when picked
            (let [rec (or picked.value picked)]
              (when rec
                (resume-session! api state (or rec.path rec.id rec)))))))))

(fn register-new [api]
  (api.register :command
    {:name :new
     :order 10
     :description "Reset the current conversation and start a fresh session"
     :idle-only? true
     :handler (fn [_args state]
                (when state.close-session (state.close-session state.session))
                (set state.opts.active-tool-names {})
                (set state.agent
                     (state.make-agent-from-opts
                       state.opts state.on-event state.agent-extra))
                (steering.clear-queues!)
                (when state.update-queue-status (state.update-queue-status))
                (set state.session (state.open-session state.opts))
                (api.session.set-info!
                  (and state.session-info (state.session-info state.session))
                  state.session)
                (set state.flush (state.make-flush state.agent state.session))
                (api.emit {:type :reset-conversation :reason :new})
                (api.emit
                  {:type :set-status-info
                   :info {:provider state.opts.provider
                          :model state.agent.model
                          :thinking-status state.agent.thinking-status}})
                (api.emit
                  {:type :assistant-text
                   :text "✓ New session started"}))}))

(fn join-tostring [xs sep]
  (let [out []]
    (each [_ x (ipairs (or xs []))]
      (table.insert out (tostring x)))
    (table.concat out (or sep ", "))))

(fn format-extension-line [item]
  (let [changed (or item.changed 0)
        checked (or item.checked 0)
        status item.status
        modules (or item.changed-modules [])]
    (if (not= status :loaded)
        (.. "    " (tostring item.name) " (failed: " (tostring status) ")")
        (.. "    " (tostring item.name) " (" (tostring changed)
            "/" (tostring checked) " changed)"
            (if (> (length modules) 0)
                (.. ": " (join-tostring modules ", "))
                "")))))

(fn interesting-extension-reload? [item]
  (or (not= item.status :loaded)
      (> (or item.changed 0) 0)))

(fn format-reload-summary [core-summary ext-summary msg-count]
  (let [core (or core-summary {:reloaded 0 :changed 0 :failed 0})
        ext (or ext-summary {:loaded 0 :changed 0 :failed 0 :extensions []})
        title (if (or (> (or core.failed 0) 0)
                      (> (or ext.failed 0) 0))
                  "/reload (errors)"
                  "/reload")
        lines [(.. title
                   " core " (tostring core.changed) "/"
                   (tostring (or core.checked core.reloaded))
                   " changed, " (tostring core.reloaded) " reloaded; ext "
                   (tostring ext.changed) "/" (tostring ext.loaded)
                   " changed; msgs " (tostring msg-count))]]
    (let [interesting []]
      (each [_ item (ipairs (or ext.extensions []))]
        (when (interesting-extension-reload? item)
          (table.insert interesting item)))
      (when (> (length interesting) 0)
        (table.insert lines "")
        (table.insert lines "extensions:")
        (each [_ item (ipairs interesting)]
          (table.insert lines (format-extension-line item))))
      (when (> (length (or core.changed-modules [])) 0)
        (table.insert lines "")
        (table.insert lines (.. "core changed: "
                                (join-tostring core.changed-modules ", ")))))
    (table.concat lines "\n")))


(local RELOAD-PHASE-WARN-MS 250)

(fn record-reload-phase! [records phase start-ms ?extra]
  (let [elapsed (- (process.monotonic-ms) start-ms)
        rec {:phase phase :elapsed-ms elapsed}]
    (each [k v (pairs (or ?extra {}))]
      (tset rec k v))
    (table.insert records rec)
    (when (>= elapsed RELOAD-PHASE-WARN-MS)
      (log.warn
        (string.format "reload phase=%s elapsed_ms=%d"
                       (tostring phase) elapsed)))
    rec))

(fn format-reload-timings [records]
  (let [parts []]
    (each [_ rec (ipairs (or records []))]
      (table.insert parts (.. (tostring rec.phase) "="
                              (tostring (or rec.elapsed-ms 0)) "ms")))
    (when (> (length parts) 0)
      (.. "timings: " (table.concat parts ", ")))))

(fn append-reload-timings [text records]
  (let [line (format-reload-timings records)]
    (if line (.. text "\n" line) text)))

(fn append-reload-diagnostics [text records truncated?]
  (let [important []]
    (each [_ rec (ipairs records)]
      (when (or (= rec.level :warn) (= rec.level :error))
        (table.insert important rec)))
    (if (and (= (length important) 0) (not truncated?))
        text
        (let [lines [text "" "diagnostics:"]]
          (when truncated?
            (table.insert lines "    [warn] earlier reload logs left the recent-log buffer"))
          (each [_ rec (ipairs important)]
            (table.insert lines (.. "    [" (tostring rec.level) "] " rec.message)))
          (table.concat lines "\n")))))

(fn merge-reload-summary! [summary extra]
  (when (and summary extra)
    (set summary.loaded (+ (or summary.loaded 0) (or extra.loaded 0)))
    (set summary.changed (+ (or summary.changed 0) (or extra.changed 0)))
    (set summary.failed (+ (or summary.failed 0) (or extra.failed 0)))
    (when (not summary.extensions)
      (set summary.extensions []))
    (each [_ item (ipairs (or extra.extensions []))]
      (table.insert summary.extensions item))))

(fn reload-tui-once! [api state ext-summary]
  "Reload the active TUI presenter once at the end of /reload. This is kept
   outside the cooperative extension pass so the running event loop is not
   swapped mid-yield; if it succeeds, ask the presenter to re-init and perform
   exactly one full redraw."
  (when state.load-extensions
    (let [(ok? result) (pcall state.load-extensions state.opts
                              {:interactive? true
                               :reload? true
                               :only-names {:tui true}})]
      (if ok?
          (do
            (merge-reload-summary! ext-summary result)
            (api.emit {:type :reinit-presenter}))
          (do
            (merge-reload-summary! ext-summary
                                   {:loaded 0 :changed 0 :failed 1
                                    :extensions [{:name :tui :status :error
                                                  :error (tostring result)
                                                  :checked 0 :changed 0
                                                  :changed-modules []}]})
            (api.emit {:type :error :error (.. "reload: tui: " (tostring result))}))))))

(fn perform-reload! [api state yield! ?opts]
  "Run the shared reload operation. The caller supplies a cooperative yield so
   slash-command and agent-tool invocations use their existing turn coroutine."
  (let [yield! (or yield! (fn [_progress] nil))
        timings []
        log-cursor (log.cursor)]
    (yield! {:phase :reload-start})
    (var failures [])
    (var core-summary nil)
    (let [start-ms (process.monotonic-ms)
          (_n core-failures summary) (state.reload-modules yield! ?opts)]
      (set failures core-failures)
      (set core-summary summary)
      (record-reload-phase! timings :core start-ms
                            {:checked (or (?. summary :checked) 0)
                             :reloaded (or (?. summary :reloaded) 0)}))
    (yield! {:phase :after-core})
    (var ext-summary nil)
    (when state.load-extensions
      (let [start-ms (process.monotonic-ms)]
        (set ext-summary
             (state.load-extensions
               state.opts
               {:interactive? true
                :reload? true
                :skip-names {:tui true}
                :yield yield!}))
        (record-reload-phase! timings :extensions start-ms
                              {:loaded (or (?. ext-summary :loaded) 0)
                               :changed (or (?. ext-summary :changed) 0)})))
    (yield! {:phase :after-extensions})
    (let [start-ms (process.monotonic-ms)]
      (reload-tui-once! api state ext-summary)
      (record-reload-phase! timings :tui start-ms))
    ;; Keep the TUI presenter reload atomic, but release control immediately
    ;; after it so the event loop can repaint before provider/agent rebuilds.
    (yield! {:phase :after-tui})
    (when state.reload-model-providers
      (let [start-ms (process.monotonic-ms)
            count (state.reload-model-providers)]
        (record-reload-phase! timings :model-providers start-ms
                              {:count count})))
    (yield! {:phase :after-model-providers})
    (let [start-ms (process.monotonic-ms)]
      (set state.session-backend (api.session.active-backend))
      (record-reload-phase! timings :session-backend start-ms))
    (let [saved state.agent.messages
          start-ms (process.monotonic-ms)
          new-agent (state.make-agent-from-opts state.opts state.on-event state.agent-extra)]
      (record-reload-phase! timings :agent-rebuild start-ms)
      ;; Keep the messages table shared with an in-flight agent tool call. Its
      ;; result and follow-up response are then visible to the replacement agent.
      (set new-agent.messages saved)
      (set state.agent new-agent)
      (let [status-start-ms (process.monotonic-ms)]
        (when state.update-queue-status (state.update-queue-status))
        (record-reload-phase! timings :status status-start-ms))
      (each [_ f (ipairs failures)]
        (api.emit {:type :error :error (.. "reload: " f)}))
      (let [summary-start-ms (process.monotonic-ms)
            (reload-logs logs-truncated?) (log.list-recent log-cursor)
            base-text (format-reload-summary core-summary ext-summary (length saved))]
        (record-reload-phase! timings :summary summary-start-ms)
        (let [text (append-reload-diagnostics
                     (append-reload-timings base-text timings)
                     reload-logs logs-truncated?)]
          (values text (or (> (length failures) 0)
                           (> (or (?. core-summary :failed) 0) 0)
                           (> (or (?. ext-summary :failed) 0) 0))))))))

(fn register-reload [api]
  (api.register :command
                {:name :reload
                 :order 30
                 :description "Hot-reload core modules and source overlays"
                 :idle-only? true
                 :handler
                 (fn [args state]
                   (api.emit {:type :assistant-text
                              :text "reload> reloading core modules and extensions…"})
                   (set state.cancel-requested? false)
                   (set state.busy? true)
                   (set state.turn
                        (coroutines.create
                          (fn []
                            (let [(text _error?)
                                  (perform-reload! api state
                                    (fn [_progress] (coroutine.yield))
                                    {:force? (= (trim args) "--all")})]
                              (api.emit {:type :assistant-text :text text}))))))})
  (api.register :tool
    {:name :reload
     :label "Reload"
     :exposure :search
     :snippet "Hot-reload fen from source overlays"
     :description "Hot-reload fen core modules, extensions, source overlays, and model-provider metadata for self-investigation. The conversation and session are preserved."
     :parameters {:type :object
                  :properties {:force {:type :boolean
                                       :description "Reload all core modules even when unchanged"}}}
     :execute (fn [args ctx ?yield!]
                (if (not ctx.state)
                    {:content [(types.text-block "reload requires an interactive run state")]
                     :is-error? true}
                    (let [(text error?) (perform-reload! api ctx.state ?yield!
                                          {:force? (= args.force true)})]
                      ;; Registration cleanup/replay completes during reload.
                      ;; Refresh both agent identities from the live registry so
                      ;; tool_search can discover newly added tools immediately.
                      (let [fresh-tools ((. (require :fen.core.extensions.register.tool)
                                            :merged) [])]
                        (when ctx.state.agent
                          (set ctx.state.agent.tools fresh-tools))
                        (when ctx.agent
                          (set ctx.agent.tools fresh-tools)))
                      {:content [(types.text-block text)] :is-error? error?})))}))

;; @doc fen.extensions.sessions.commands.session.register
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
                (api.commands.dispatch (.. "/new " (or args "")) state))})
  (api.register :command
    {:name :sessions
     :order 25
     :description "Pick a recent session to resume (overlay)"
     :idle-only? true
     :handler (fn [_args state] (pick-session! api state))})
  (api.register :command
    {:name :resume
     :order 26
     :description "Resume a session (overlay if no arg; id/prefix/path/index if given)"
     :idle-only? true
     :handler (fn [args state]
                (let [target (trim args)]
                  (if (= target "")
                      (pick-session! api state)
                      (resume-session! api state target))))})
  (register-reload api)
  (api.register :command
    {:name :r
     :order 40
     :description "Alias for /reload"
     :idle-only? true
     :handler (fn [args state]
                (api.commands.dispatch (.. "/reload " (or args "")) state))})

  (api.register :introspect
    {:name :active-session
     :description "Current session selection and persistence backend summary"
     :snapshot (fn [_]
                 (let [info (api.session.info)
                       backend (api.session.active-backend)]
                   {:enabled? (not= info nil)
                    :backend (or (?. info :backend) (?. backend :name))
                    :id (?. info :id)
                    :path (?. info :path)}))}))

M
