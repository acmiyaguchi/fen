(local state (require :core.extensions.state))
(local util (require :core.extensions.util))
(local log (require :util.log))

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

M
