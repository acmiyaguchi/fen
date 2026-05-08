(local levels {:debug 10 :info 20 :warn 30 :error 40})

(local current-level
  (let [env (or (os.getenv :FEN_LOG) :info)]
    (or (. levels env) 20)))

(fn write [level msg]
  (when (>= (. levels level) current-level)
    (io.stderr:write (string.format "[%s] %s\n" level msg))))

;; @doc fen.util.log.debug
;; kind: function
;; signature: (debug msg) -> nil
;; summary: Write a debug-level message to stderr when FEN_LOG enables verbose diagnostics.
;; tags: util logging
;; @doc fen.util.log.info
;; kind: function
;; signature: (info msg) -> nil
;; summary: Write an info-level message to stderr when the configured log level allows normal diagnostics.
;; tags: util logging
;; @doc fen.util.log.warn
;; kind: function
;; signature: (warn msg) -> nil
;; summary: Write a warning-level message to stderr for recoverable problems such as malformed config or extension failures.
;; tags: util logging
;; @doc fen.util.log.error
;; kind: function
;; signature: (error msg) -> nil
;; summary: Write an error-level message to stderr for severe runtime failures that should always be visible.
;; tags: util logging
{:debug (fn [msg] (write :debug msg))
 :info  (fn [msg] (write :info msg))
 :warn  (fn [msg] (write :warn msg))
 :error (fn [msg] (write :error msg))}
