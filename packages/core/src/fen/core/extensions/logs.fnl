;; Owner-tagged extension log records with durable JSONL persistence.
;; State stays in fen.core.extensions.state so /reload preserves the ring.

(local state (require :fen.core.extensions.state))
(local json (require :fen.util.json))
(local jsonl (require :fen.util.jsonl))
(local redact (require :fen.util.redact))
(local path (require :fen.util.path))
(local stderr-log (require :fen.util.log))

(local M {})
(local MAX-LOGS 500)

(fn log-path []
  (when (= state.log-path nil)
    (set state.log-path (.. (path.state-dir :fen) "/logs.jsonl")))
  state.log-path)

(fn message [value]
  (if (= (type value) :string)
      (redact.scrub-string value)
      (let [(ok? encoded) (pcall json.encode (redact.sanitize value))]
        (if ok? encoded (redact.scrub-string (tostring value))))))

(fn record [owner level value]
  (let [rec {:owner (tostring (or owner :core))
             :level (tostring (or level :info))
             :timestamp (stderr-log.timestamp)
             :msg (message value)}]
    (when state.session.info (set rec.session (redact.sanitize state.session.info)))
    rec))

(fn append! [rec]
  (jsonl.append! state (log-path) rec
                (fn [err]
                  (stderr-log.warn (.. "logs: append failed: " err)))))

(fn trim! []
  (while (> (length state.logs) MAX-LOGS)
    (table.remove state.logs 1)))

;; @doc fen.core.extensions.logs.record!
;; kind: function
;; signature: (record! owner level value) -> LogRecord|nil
;; summary: For enabled levels, sanitize and retain one owner-tagged extension log record, append it to logs.jsonl, and mirror it through fen.util.log; disabled levels avoid all record construction and file I/O.
;; tags: extensions logs diagnostics
(fn M.record! [owner level value]
  ;; Info and higher remain in the ring by default; disabled debug logs are near-free.
  (let [level (or level :info)]
    (when (stderr-log.enabled? level)
      (when (= state.logs nil) (set state.logs []))
      (let [rec (record owner level value)
            writer (. stderr-log level)]
        (table.insert state.logs rec)
        (trim!)
        (append! rec)
        (if writer
            (writer (.. "[" rec.owner "] " rec.msg))
            (stderr-log.info (.. "[" rec.owner "] " rec.msg)))
        rec))))

;; @doc fen.core.extensions.logs.list
;; kind: function
;; signature: (list) -> [LogRecord]
;; summary: Return the bounded persistent extension log ring for structured introspection.
;; tags: extensions logs introspection
(fn M.list []
  (when (= state.logs nil) (set state.logs []))
  state.logs)

(tset M :log-path log-path)
M
