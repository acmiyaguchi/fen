;; Session persistence lifecycle for an interactive fen process.
;;
;; The CLI entrypoint chooses a backend and wires the presenter loop, but the
;; policy for opening, resuming, flushing, and closing transcript sessions lives
;; here so main.fnl stays focused on process entry/orchestration.

(local events (require :fen.core.extensions.events))
(local session-backend-registry
       (require :fen.core.extensions.register.session_backend))
(local log (require :fen.util.log))
(local path (require :fen.util.path))

(local M {})

(local OWNER :session_persistence)
(tset M :OWNER OWNER)

(fn M.cwd []
  "Return the authoritative physical cwd used for session grouping."
  ;; PWD is caller-controlled and may disagree with the process cwd. Session
  ;; mutation authorization must therefore use a physical probe of `.`.
  (or (path.pwd-physical ".") "/"))

;; @doc fen.session_lifecycle.resolve-backend
;; kind: function
;; signature: (resolve-backend opts) -> SessionBackend
;; summary: Resolve and mark the active session backend, while allowing --no-session to disable writes without disabling replay/discovery.
;; tags: sessions lifecycle cli
(fn M.resolve-backend [opts]
  (let [name (or opts.session-backend :jsonl)
        backend (session-backend-registry.find name)]
    (when (not backend)
      (io.stderr:write (.. "unknown --session-backend: " (tostring name) "\n"))
      (os.exit 2))
    (session-backend-registry.set-active! name)
    (when opts.no-session?
      (session-backend-registry.set-info! nil nil))
    backend))

;; @doc fen.session_lifecycle.backend-info
;; kind: function
;; signature: (backend-info backend session) -> SessionInfo|nil
;; summary: Return backend-specific session info when available, else a generic info record.
;; tags: sessions lifecycle introspection
(fn M.backend-info [backend session]
  (when session
    (if (and backend (= (type backend.info) :function))
        (backend.info session)
        {:backend (?. backend :name)
         :id session.id
         :path session.path
         :cwd session.cwd})))

;; @doc fen.session_lifecycle.close!
;; kind: function
;; signature: (close! backend session) -> nil
;; summary: Close the active session handle and clear cached session info.
;; tags: sessions lifecycle persistence
(fn M.close! [backend session]
  (when (and backend session)
    (backend.close session))
  (session-backend-registry.set-info! nil nil))

;; @doc fen.session_lifecycle.open
;; kind: function
;; signature: (open opts backend) -> Session|nil
;; summary: Open a new transcript handle unless session writes are disabled.
;; tags: sessions lifecycle persistence
(fn M.open [opts backend]
  (when (and backend (not opts.no-session?))
    (let [s (backend.open (M.cwd))]
      (session-backend-registry.set-info! (M.backend-info backend s) s)
      s)))

;; @doc fen.session_lifecycle.start!
;; kind: function
;; signature: (start! opts agent backend) -> session, replayed-count
;; summary: Open or resume the active transcript and replay --continue messages into the agent.
;; tags: sessions lifecycle persistence replay
(fn M.start! [opts agent backend]
  (if (not backend)
      (values nil 0)
      opts.continue?
      (let [p (backend.latest (M.cwd))]
        (if (not p)
            (do (log.warn "session: --continue but no prior session found")
                (values (M.open opts backend) 0))
            (let [msgs (backend.load p)
                  s (if opts.no-session? nil (backend.open-existing p))]
              (each [_ m (ipairs msgs)]
                (table.insert agent.messages m))
              (session-backend-registry.set-info! (M.backend-info backend s) s)
              (values s (length msgs)))))
      (values (M.open opts backend) 0)))

(fn assistant-present? [messages]
  (var found? false)
  (each [_ m (ipairs messages)]
    (when (= m.role :assistant)
      (set found? true)))
  found?)

;; @doc fen.session_lifecycle.make-flush
;; kind: function
;; signature: (make-flush backend agent session initial-last-saved) -> fn
;; summary: Return a closure that appends new messages after the first assistant message is present.
;; tags: sessions lifecycle persistence
(fn M.make-flush [backend agent session initial-last-saved]
  "Returns a closure that appends any messages added since the last call.
   Tracks `last-saved` across invocations. Like pi-mono, holds early user-only
   messages in memory until the first assistant (including :aborted) lands, so
   a crashed idle prompt doesn't leave an orphan one-message session."
  (var last-saved (or initial-last-saved 0))
  (fn []
    (when (and backend session (assistant-present? agent.messages))
      (while (< last-saved (length agent.messages))
        (set last-saved (+ last-saved 1))
        (backend.append session (. agent.messages last-saved))))))

;; @doc fen.session_lifecycle.install!
;; kind: function
;; signature: (install! state) -> nil
;; summary: Bridge :message-appended events into the state's current flush and status-refresh closures.
;; tags: sessions lifecycle events
(fn M.install! [state]
  "Bridge :message-appended into the existing session flush closure.
   The closure is looked up through mutable state so /new, /resume, /reload,
   /model, and /handoff do not need to reattach per-agent callbacks."
  (events.unregister-by-owner OWNER)
  (events.on
    :message-appended
    (fn [ev]
      (when (= ev.agent state.agent)
        (when state.flush (state.flush))
        (when state.update-queue-status (state.update-queue-status))))
    OWNER))

;; @doc fen.session_lifecycle.uninstall!
;; kind: function
;; signature: (uninstall!) -> nil
;; summary: Remove the process-level session lifecycle event bridge.
;; tags: sessions lifecycle events
(fn M.uninstall! []
  (events.unregister-by-owner OWNER))

M
