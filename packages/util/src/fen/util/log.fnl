(local log-sink (require :fen.util.log_sink))

(local levels {:debug 10 :info 20 :warn 30 :error 40})

(fn level-from-env []
  ;; FEN_LOG is the CLI-host default; an unknown value falls back to :info.
  (or (. levels (or (os.getenv :FEN_LOG) :info)) (. levels :info)))

(fn ensure-level! []
  ;; Initialize the threshold from the env default only once. Held on the
  ;; non-reloadable log_sink table so a host-set level survives /reload and
  ;; is not clobbered by re-reading FEN_LOG on every behavior reload.
  (when (= log-sink.level nil)
    (set log-sink.level (level-from-env))))

(fn current-level []
  (ensure-level!)
  log-sink.level)

;; @doc fen.util.log.set-level!
;; kind: function
;; signature: (set-level! level) -> boolean
;; summary: Set the active log threshold at runtime by name (:debug/:info/:warn/:error). Returns true when applied, false for an unknown level. Overrides the FEN_LOG default and persists across /reload; lets an embedded host set the level without env vars.
;; tags: util logging
(fn set-level! [level]
  (let [n (. levels level)]
    (if n
        (do (set log-sink.level n) true)
        false)))

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

(fn enabled? [level]
  (>= (or (. levels level) (. levels :info)) (current-level)))

(fn write [level msg]
  (when (enabled? level)
    (let [ts (timestamp)
          _recorded (record! level msg ts)
          fallback-line (string.format "[%s] %s\n" level msg)]
      (if (log-sink.active?)
          (let [(ok? _err) (log-sink.write-line
                             (string.format "[%s] [%s] %s"
                                            ts level msg))]
            ;; write-line clears the sink on failure (disk full, EIO,
            ;; closed FILE*); surface the line through the fallback seam so
            ;; the message isn't silently dropped.
            (when (not ok?) (log-sink.write-fallback fallback-line)))
          ;; No file sink: route through log_sink's fallback indirection
          ;; (stderr by default, host-injectable) rather than a hard-coded
          ;; io.stderr that may not exist in an embedded VM. The recent ring
          ;; already holds the line via record!.
          (log-sink.write-fallback fallback-line)))))

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
 :enabled? enabled?
 :set-level! set-level!
 :cursor cursor
 :list-recent list-recent}
