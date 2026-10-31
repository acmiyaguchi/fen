;; In-process event bus; lifecycle event payloads are sanitized before emit.

(local state (require :fen.core.extensions.state))
(local contrib (require :fen.core.extensions.contrib))
(local usage-ledger (require :fen.core.extensions.usage_ledger))
(local log (require :fen.util.log))
(local jsonl (require :fen.util.jsonl))
(local redact (require :fen.util.redact))
(local path (require :fen.util.path))
(local diagnostics (require :fen.core.diagnostics))

(local M {})

(local MAX-ERRORS 100)

(local first-line (. (require :fen.util.text) :first-line))

;; @doc fen.core.extensions.events.error-log-path
;; kind: function
;; signature: (error-log-path) -> string
;; summary: Lazily compute and return the JSONL file path where extension event-bus failures are persisted.
;; tags: extensions events diagnostics
(fn M.error-log-path []
  (when (= state.error-log-path nil)
    (set state.error-log-path (.. (path.state-dir :fen) "/errors.jsonl")))
  state.error-log-path)

(fn trim-errors! []
  (while (> (length state.errors) MAX-ERRORS)
    (table.remove state.errors 1)))

(fn error-event? [ev]
  (or (= ev.type :error) (= ev.type :extension-error)))

(fn sanitize-error-event [ev]
  (let [rec {:type ev.type
             :timestamp (log.timestamp)
             :cwd (path.cwd)
             :error (redact.scrub-string (first-line (or ev.error ev.text "")))}]
    (when ev.traceback
      (set rec.traceback (redact.scrub-string (tostring ev.traceback))))
    (when ev.owner (set rec.owner ev.owner))
    (when ev.event (set rec.event ev.event))
    (when ev.source (set rec.source ev.source))
    (let [runtime (diagnostics.runtime-info)]
      (when runtime (set rec.runtime runtime)))
    (when state.session.info
      (set rec.session (redact.sanitize state.session.info)))
    rec))

(fn append-error-log! [rec]
  (jsonl.append! state (M.error-log-path) rec
                 (fn [err]
                   (log.warn (.. "errors: append failed: " err)))))

(fn record-error! [ev]
  (when (error-event? ev)
    (when (= state.errors nil) (set state.errors []))
    (let [rec (sanitize-error-event ev)]
      (table.insert state.errors rec)
      (trim-errors!)
      (append-error-log! rec))))

;; @doc fen.core.extensions.events.list-errors
;; kind: function
;; signature: (list-errors) -> [ExtensionError]
;; summary: Return the bounded in-memory list of sanitized extension error records captured by the event bus.
;; tags: extensions events diagnostics
(fn M.list-errors []
  (when (= state.errors nil) (set state.errors []))
  state.errors)

(fn report-handler-error [entry ev err]
  "Surface extension event-handler failures without recursive diagnostics."
  (let [event-type (?. ev :type)
        owner (or entry.__owner :anonymous)
        summary (first-line err)
        msg (.. "extension handler failed" " owner=" (tostring owner) " event="
                (tostring event-type) ": " summary)]
    (log.warn msg)
    (when (not= event-type :extension-error)
      (M.emit {:type :extension-error
               :owner owner
               :event event-type
               :error summary
               :traceback (tostring err)}))))

(fn snapshot-bucket [bucket]
  (let [out []]
    (when bucket
      (each [_ entry (ipairs bucket)]
        (table.insert out entry)))
    out))

(fn bucket-contains? [bucket target]
  (var found? false)
  (when bucket
    (each [_ entry (ipairs bucket) &until found?]
      (when (= entry target)
        (set found? true))))
  found?)

(fn dispatch-bucket [bucket snapshot ev]
  (when bucket
    (each [_ entry (ipairs snapshot)]
      ;; An earlier handler may have removed this entry from the live bucket.
      (when (bucket-contains? bucket entry)
        (let [(ok? err) (xpcall #(entry.fn ev) debug.traceback)]
          (when (not ok?)
            (report-handler-error entry ev err)))))))

(fn M.emit [ev]
  "Dispatch ev to handlers[ev.type] and the `:*` wildcard bucket."
  (when (and ev ev.type)
    ;; Snapshot before dispatch: handlers added mid-emit wait for the next emit.
    (let [bucket (. state.handlers ev.type)
          wildcard-bucket (. state.handlers :*)
          snapshot (snapshot-bucket bucket)
          wildcard-snapshot (snapshot-bucket wildcard-bucket)]
      (record-error! ev)
      ;; The single writer of the usage ledger: every :llm-end, whoever emits it.
      (when (= ev.type :llm-end)
        (usage-ledger.record! ev.usage))
      (dispatch-bucket bucket snapshot ev)
      (dispatch-bucket wildcard-bucket wildcard-snapshot ev)))
  nil)

(fn M.on [event-name handler ?owner]
  "Subscribe handler to event-name. Returns unsubscribe function. Buckets are
   views folded in owner load order, so a reloaded owner keeps its place."
  (let [(_entry unsubscribe) (contrib.add! ?owner :handlers event-name
                                           {:fn handler})]
    unsubscribe))

;; @doc fen.core.extensions.events.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove every event handler tagged with owner from all event buckets during extension reload or teardown.
;; tags: extensions events reload
(fn M.unregister-by-owner [owner]
  (contrib.drop-view! owner :handlers))

;; @doc fen.core.extensions.events.list
;; kind: function
;; signature: (list) -> table
;; summary: Return a safe introspection table of subscribed event names and handler owners without exposing handler functions.
;; tags: extensions events introspection
(fn M.list []
  (let [out {}]
    (each [event-name bucket (pairs state.handlers)]
      (let [entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.__owner}))
        (tset out event-name entries)))
    out))

M
