(local log-sink (require :fen.util.log_sink))

(local levels {:debug 10 :info 20 :warn 30 :error 40})

(local current-level
  (let [env (or (os.getenv :FEN_LOG) :info)]
    (or (. levels env) 20)))

(fn timestamp []
  (os.date "!%Y-%m-%dT%H:%M:%SZ"))

(fn write [level msg]
  (when (>= (. levels level) current-level)
    (let [stderr-line (string.format "[%s] %s\n" level msg)]
      (if (log-sink.active?)
          (let [(ok? _err) (log-sink.write-line
                             (string.format "[%s] [%s] %s"
                                            (timestamp) level msg))]
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
 :timestamp timestamp}
