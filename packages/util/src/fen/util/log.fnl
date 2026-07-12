(local log-sink (require :fen.util.log_sink))

(local levels {:debug 10 :info 20 :warn 30 :error 40})

(local current-level
  (let [env (or (os.getenv :FEN_LOG) :info)]
    (or (. levels env) 20)))

(local MAX-RECENT 100)

(fn ensure-recent! []
  (when (= log-sink.recent nil) (set log-sink.recent []))
  (when (= log-sink.next-seq nil) (set log-sink.next-seq 0)))

(fn record! [level message timestamp]
  (ensure-recent!)
  (set log-sink.next-seq (+ log-sink.next-seq 1))
  (table.insert log-sink.recent {:seq log-sink.next-seq
                                 :timestamp timestamp
                                 :level level
                                 :message (tostring message)})
  (while (> (length log-sink.recent) MAX-RECENT)
    (table.remove log-sink.recent 1))
  log-sink.next-seq)

(fn cursor []
  (ensure-recent!)
  log-sink.next-seq)

(fn list-recent [?after-seq]
  (ensure-recent!)
  (let [out []
        after (or ?after-seq 0)]
    (each [_ rec (ipairs log-sink.recent)]
      (when (> rec.seq after)
        (table.insert out {:seq rec.seq :timestamp rec.timestamp
                           :level rec.level :message rec.message})))
    (let [first-retained (?. log-sink.recent 1 :seq)]
      (values out (and first-retained (< after (- first-retained 1)))))))

(fn timestamp []
  (os.date "!%Y-%m-%dT%H:%M:%SZ"))

(fn write [level msg]
  (when (>= (. levels level) current-level)
    (let [ts (timestamp)
          _recorded (record! level msg ts)
          stderr-line (string.format "[%s] %s\n" level msg)]
      (if (log-sink.active?)
          (let [(ok? _err) (log-sink.write-line
                             (string.format "[%s] [%s] %s"
                                            ts level msg))]
            ;; write-line clears the sink on failure (disk full, EIO,
            ;; closed FILE*); surface the line on stderr so the message
            ;; isn't silently dropped.
            (when (not ok?) (io.stderr:write stderr-line)))
          (io.stderr:write stderr-line)))))

;; @doc fen.util.log.debug
;; kind: function
;; signature: (debug msg) -> nil
;; summary: Write a debug-level message when FEN_LOG enables verbose diagnostics; lands in the active log sink when one is open, otherwise stderr.
;; tags: util logging
;; @doc fen.util.log.info
;; kind: function
;; signature: (info msg) -> nil
;; summary: Write an info-level message when the configured log level allows normal diagnostics; lands in the active log sink when one is open, otherwise stderr.
;; tags: util logging
;; @doc fen.util.log.warn
;; kind: function
;; signature: (warn msg) -> nil
;; summary: Write a warning-level message for recoverable problems such as malformed config or extension failures; lands in the active log sink when one is open, otherwise stderr.
;; tags: util logging
;; @doc fen.util.log.error
;; kind: function
;; signature: (error msg) -> nil
;; summary: Write an error-level message for severe runtime failures that should always be visible; lands in the active log sink when one is open, otherwise stderr.
;; tags: util logging
;; @doc fen.util.log.timestamp
;; kind: function
;; signature: (timestamp) -> string
;; summary: Return the current UTC time formatted as RFC3339/ISO8601 for diagnostic file output.
;; tags: util logging time
{:debug (fn [msg] (write :debug msg))
 :info  (fn [msg] (write :info msg))
 :warn  (fn [msg] (write :warn msg))
 :error (fn [msg] (write :error msg))
 :timestamp timestamp
 :cursor cursor
 :list-recent list-recent}
