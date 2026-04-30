(local levels {:debug 10 :info 20 :warn 30 :error 40})

(local current-level
  (let [env (or (os.getenv :FEN_LOG) :info)]
    (or (. levels env) 20)))

(fn write [level msg]
  (when (>= (. levels level) current-level)
    (io.stderr:write (string.format "[%s] %s\n" level msg))))

{:debug (fn [msg] (write :debug msg))
 :info  (fn [msg] (write :info msg))
 :warn  (fn [msg] (write :warn msg))
 :error (fn [msg] (write :error msg))}
