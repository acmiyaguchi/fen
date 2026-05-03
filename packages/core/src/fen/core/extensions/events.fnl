;; In-process event bus.
;;
;; Lifecycle events emitted by core/main:
;;   {:type :message-appended :message msg :agent agent :index n}
;;     Emitted by fen.core.agent immediately after agent.messages grows.
;;   {:type :agent-started :agent agent :provider provider :model model :cwd cwd}
;;     Emitted once per run after setup and before the first new step. Payload is
;;     intentionally sanitized; raw CLI opts may contain internal/sensitive data.
;;   {:type :agent-shutdown :agent agent :reason reason :error err}
;;     Emitted once per run during teardown; :error is present for crashed paths.
;;
;; Sits alongside register/ rather than inside it because subscribers come in
;; through `api.on`, not `api.register :event` — different verb at the public
;; api. Owner-tagging and the unregister-by-owner sweep still match the
;; per-kind register modules' shape.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local log (require :fen.util.log))

(local M {})

(fn append-handler [event-name entry]
  (let [bucket (or (. state.handlers event-name) [])]
    (table.insert bucket entry)
    (tset state.handlers event-name bucket)))

(fn remove-handler [event-name entry]
  (let [bucket (. state.handlers event-name)]
    (when bucket
      (util.remove-where bucket (fn [e _] (= e entry))))))

(fn report-handler-error [entry ev err]
  "Surface extension event-handler failures without recursive diagnostics."
  (let [event-type (?. ev :type)
        owner (or entry.owner :anonymous)
        msg (.. "extension handler failed"
                " owner=" (tostring owner)
                " event=" (tostring event-type)
                ": " (tostring err))]
    (log.warn msg)
    (when (not= event-type :extension-error)
      (M.emit {:type :extension-error
               :owner owner
               :event event-type
               :error (tostring err)}))))

(fn dispatch-bucket [bucket ev]
  (when bucket
    (each [_ entry (ipairs bucket)]
      (let [(ok? err) (pcall entry.fn ev)]
        (when (not ok?)
          (report-handler-error entry ev err))))))

(fn M.emit [ev]
  "Dispatch ev to handlers[ev.type] and the `:*` wildcard bucket."
  (when (and ev ev.type)
    (dispatch-bucket (. state.handlers ev.type) ev))
  (dispatch-bucket (. state.handlers :*) ev)
  nil)

(fn M.on [event-name handler ?owner]
  "Subscribe handler to event-name. Returns unsubscribe function."
  (let [entry {:fn handler :owner ?owner}]
    (append-handler event-name entry)
    (fn [] (remove-handler event-name entry))))

(fn M.unregister-by-owner [owner]
  (each [_ bucket (pairs state.handlers)]
    (util.remove-where bucket (fn [e _] (= e.owner owner)))))

(fn M.list []
  (let [out {}]
    (each [event-name bucket (pairs state.handlers)]
      (let [entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.owner}))
        (tset out event-name entries)))
    out))

M
