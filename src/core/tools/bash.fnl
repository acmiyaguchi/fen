(local util (require :core.tools.util))
(local truncate (require :core.tools.truncate))

(fn read-small-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

(fn read-pidfile [path]
  (let [s (read-small-file path)
        pid (and s (string.match s "^(%d+)"))]
    (and pid (tonumber pid))))

(fn kill-pid [pid]
  "Best-effort cancel cleanup for io.popen commands."
  (when pid
    (os.execute (.. "kill -TERM " (tostring pid) " 2>/dev/null; "
                    "sleep 0.1; "
                    "kill -KILL " (tostring pid) " 2>/dev/null"))))

(fn bash-spawn-command [inner timeout-int pidfile]
  "Wrap the user command so the child PID is written before exec."
  (let [script "echo $$ > \"$1\"; shift; exec \"$@\""
        argv (if (and timeout-int (> timeout-int 0))
                 ["timeout" (.. (tostring timeout-int) "s") "sh" "-c" inner]
                 ["sh" "-c" inner])
        parts ["sh" "-c" (util.shellquote script) "agent-fennel-run" (util.shellquote pidfile)]]
    (each [_ arg (ipairs argv)]
      (table.insert parts (util.shellquote arg)))
    (.. (table.concat parts " ") " 2>&1")))

(fn run-bash-impl [{: cmd : timeout : cwd} reader]
  (if (or (not cmd) (= cmd ""))
      (util.err "missing 'cmd'")
      (and cwd (not= cwd "") (not (util.dir-exists? cwd)))
      (util.err (.. "cwd does not exist: " cwd))
      (let [timeout-int (util.int-arg timeout nil)
            cd-prefix (if (and cwd (not= cwd ""))
                          (.. "cd " (util.shellquote cwd) " && ")
                          "")
            inner (.. cd-prefix cmd)
            pidfile (os.tmpname)
            spawn-cmd (bash-spawn-command inner timeout-int pidfile)
            pipe (io.popen spawn-cmd :r)]
        (if (not pipe) (util.err "io.popen failed")
            (let [(read-ok? read-result) (pcall reader pipe)]
              (when (not read-ok?)
                (kill-pid (read-pidfile pidfile)))
              (let [(_ _ code) (pipe:close)]
                (os.remove pidfile)
                (if (not read-ok?)
                    (error read-result)
                    (let [(capped _) (truncate.truncate-tail (or read-result "") nil)
                          exit-tag (if code
                                       (.. "[exit " (tostring code) "]")
                                       "[exit unknown — process killed or popen error]")]
                      (util.ok (.. capped "\n" exit-tag))))))))))

(fn run-bash [args]
  (run-bash-impl args (fn [pipe] (or (pipe:read :*a) ""))))

(fn run-bash-coop [args yield-fn]
  (let [(ok? process) (pcall require :util.process)]
    (if (not ok?)
        (run-bash args)
        (run-bash-impl args
                       (fn [pipe] (process.read-pipe-coop pipe yield-fn))))))

{:name :bash
 :label "Bash"
 :snippet "Run a shell command in the working directory"
 :description "Run a shell command and return combined stdout+stderr (intentionally merged via 2>&1; pipe to /dev/null inside the cmd if you want to drop one). Output is tail-truncated to ~50KB / 2000 lines; when truncated, the tag includes a `full output: <path>` you can pass to the read tool to inspect any region of the original."
 :parameters {:type :object
              :properties {:cmd {:type :string
                                 :description "Shell command to run"}
                           :timeout {:type :integer
                                     :description "Kill the command after N seconds (uses timeout(1))"}
                           :cwd {:type :string
                                 :description "Working directory; validated to exist before running"}}
              :required [:cmd]}
 :execute run-bash
 :execute-coop run-bash-coop}
