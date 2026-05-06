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
(local json (require :fen.util.json))
(local path (require :fen.util.path))

(local M {})

(local MAX-ERRORS 100)

(fn append-handler [event-name entry]
  (let [bucket (or (. state.handlers event-name) [])]
    (table.insert bucket entry)
    (tset state.handlers event-name bucket)))

(fn remove-handler [event-name entry]
  (let [bucket (. state.handlers event-name)]
    (when bucket
      (util.remove-where bucket (fn [e _] (= e entry))))))

(fn first-line [s]
  (let [text (tostring (or s ""))
        i (string.find text "\n" 1 true)]
    (if i (string.sub text 1 (- i 1)) text)))

(fn ensure-dir [dir]
  (os.execute (.. "mkdir -p " (path.shell-quote dir))))

(fn M.error-log-path []
  (when (= state.error-log-path nil)
    (set state.error-log-path (.. (path.state-dir :fen) "/errors.jsonl")))
  state.error-log-path)

(fn timestamp []
  (os.date "!%Y-%m-%dT%H:%M:%SZ"))

(fn trim-errors! []
  (while (> (length state.errors) MAX-ERRORS)
    (table.remove state.errors 1)))

(fn error-event? [ev]
  (or (= ev.type :error) (= ev.type :extension-error)))

(fn sanitize-error-event [ev]
  (let [rec {:type ev.type
             :timestamp (timestamp)
             :cwd (path.cwd)
             :error (first-line (or ev.error ev.text ""))}]
    (when ev.traceback (set rec.traceback (tostring ev.traceback)))
    (when ev.owner (set rec.owner ev.owner))
    (when ev.event (set rec.event ev.event))
    (when ev.source (set rec.source ev.source))
    (when state.session.info
      (set rec.session state.session.info))
    rec))

(fn append-error-log! [rec]
  (let [p (M.error-log-path)]
    (ensure-dir (path.dirname p))
    (let [(f open-err) (io.open p :a)]
      (if (not f)
          (log.warn (.. "errors: cannot open " p ": " (tostring open-err)))
          (let [(ok? err) (pcall #(f:write (.. (json.encode rec) "\n")))]
            (f:close)
            (when (not ok?)
              (log.warn (.. "errors: append failed: " (tostring err)))))))))

(fn record-error! [ev]
  (when (error-event? ev)
    (when (= state.errors nil) (set state.errors []))
    (let [rec (sanitize-error-event ev)]
      (table.insert state.errors rec)
      (trim-errors!)
      (append-error-log! rec))))

(fn M.list-errors []
  (when (= state.errors nil) (set state.errors []))
  state.errors)

(fn report-handler-error [entry ev err]
  "Surface extension event-handler failures without recursive diagnostics."
  (let [event-type (?. ev :type)
        owner (or entry.__owner :anonymous)
        summary (first-line err)
        msg (.. "extension handler failed"
                " owner=" (tostring owner)
                " event=" (tostring event-type)
                ": " summary)]
    (log.warn msg)
    (when (not= event-type :extension-error)
      (M.emit {:type :extension-error
               :owner owner
               :event event-type
               :error summary
               :traceback (tostring err)}))))

(fn dispatch-bucket [bucket ev]
  (when bucket
    (each [_ entry (ipairs bucket)]
      (let [(ok? err) (xpcall #(entry.fn ev) debug.traceback)]
        (when (not ok?)
          (report-handler-error entry ev err))))))

(fn M.emit [ev]
  "Dispatch ev to handlers[ev.type] and the `:*` wildcard bucket."
  (when (and ev ev.type)
    (record-error! ev)
    (dispatch-bucket (. state.handlers ev.type) ev))
  (dispatch-bucket (. state.handlers :*) ev)
  nil)

(fn M.on [event-name handler ?owner]
  "Subscribe handler to event-name. Returns unsubscribe function."
  (let [entry {:fn handler :__owner ?owner}]
    (append-handler event-name entry)
    (fn [] (remove-handler event-name entry))))

(fn M.unregister-by-owner [owner]
  (each [_ bucket (pairs state.handlers)]
    (util.remove-where bucket (fn [e _] (= e.__owner owner)))))

(fn M.list []
  (let [out {}]
    (each [event-name bucket (pairs state.handlers)]
      (let [entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.__owner}))
        (tset out event-name entries)))
    out))

M
