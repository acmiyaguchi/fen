;; subagent tool — delegate a focused task to a child fen process.
;;
;; Out-of-process by design (see issue #16): the child is a fresh `fen` with its
;; own context window, an agent-specific system prompt, and an optional model/
;; provider override. We spawn it with the json presenter writing a structured
;; result blob to a temp file (FEN_JSON_OUTPUT_PATH), then return the child's
;; final text plus usage/stop-reason to the parent. Cooperative yielding and
;; timeout/abort handling come free from process.run-captured.

(local types (require :fen.core.types))
(local process (require :fen.util.process))
(local runtime (require :fen.runtime))
(local path (require :fen.util.path))
(local json (require :fen.util.json))
(local discover (require :fen.extensions.subagent.discover))

(local M {})

(local DEFAULT-TIMEOUT-SECONDS 300)

(fn result [text is-error? ?details]
  (let [r {:content [(types.text-block (or text ""))]
           :is-error? (or is-error? false)}]
    (when (not= ?details nil) (set r.details ?details))
    r))

(fn write-temp [content]
  "Write CONTENT to a fresh temp file and return its path (or nil on failure)."
  (let [p (os.tmpname)
        (f err) (io.open p :w)]
    (if f
        (do (f:write (or content "")) (f:close) p)
        (do (io.stderr:write (.. "subagent: cannot write temp file " p ": "
                                 (tostring err) "\n"))
            nil))))

(fn decode-file [p]
  "Read and JSON-decode P, returning the decoded table or nil."
  (let [f (io.open p :r)]
    (when f
      (let [data (f:read :*a)]
        (f:close)
        (let [(ok? blob) (pcall json.decode (or data ""))]
          (when (and ok? (= (type blob) :table)) blob))))))

(fn build-argv [bin task sys-path cfg]
  (let [argv [bin "--presenter" "json" "--print" task
              "--system-file" sys-path "--no-session"]]
    (each [_ [flag val] (ipairs [["--model" cfg.model] ["--provider" cfg.provider]])]
      (when val
        (table.insert argv flag)
        (table.insert argv val)))
    argv))

(fn absolute-cwd [cwd]
  "Return an absolute spelling for CWD while preserving a symlink final component."
  (if (= (string.sub cwd 1 1) "/")
      cwd
      (path.realpath cwd)))

(fn task-with-cwd-context [task requested-cwd cwd physical-cwd]
  (.. "Subagent launch context:\n"
      "- Requested cwd: " requested-cwd "\n"
      "- Child PWD: " cwd "\n"
      "- Physical cwd: " physical-cwd "\n\n"
      "Treat Child PWD as the authoritative working directory for all "
      "relative paths and tool calls. If the task concerns a git worktree "
      "or diff, verify `pwd` and `git status --short` in that directory "
      "before drawing conclusions.\n\n"
      "Task:\n"
      task))

(fn run-agent [cfg agent task requested-cwd cwd physical-cwd ?yield-fn]
  (let [bin (runtime.binary-path)]
    (if (not bin)
        (result "cannot resolve fen binary to spawn subagent" true)
        (let [sys-path (write-temp cfg.body)]
          (if (not sys-path)
              (result "cannot stage subagent system prompt" true)
              (let [out-path (os.tmpname)
                    child-task (task-with-cwd-context task requested-cwd cwd physical-cwd)
                    argv (build-argv bin child-task sys-path cfg)
                    r (process.run-captured
                        {:argv argv
                         :cwd cwd
                         :env {:FEN_JSON_OUTPUT_PATH out-path
                               :PWD cwd}
                         :timeout-seconds (or cfg.timeout-seconds
                                              DEFAULT-TIMEOUT-SECONDS)
                         :spill? true}
                        ?yield-fn)
                    decoded (decode-file out-path)
                    parsed (or decoded {})]
                (os.remove sys-path)
                (os.remove out-path)
                (let [final-text (or parsed.final-text parsed.error r.output "")
                      error? (or (not= r.exit-code 0) r.timed-out? (not decoded)
                                 (= parsed.stop-reason :error))]
                  (result final-text error?
                          {:agent agent
                           :requested-cwd requested-cwd
                           :cwd cwd
                           :physical-cwd physical-cwd
                           :usage parsed.usage
                           :stop-reason parsed.stop-reason
                           :duration-ms r.duration-ms
                           :timed-out? r.timed-out?
                           :exit-code r.exit-code}))))))))

(fn invalid-agent-result [agent err]
  (result (.. "invalid agent definition " err.file ": " err.reason) true
          {:agent agent :path err.file :reason err.reason}))

(fn execute [args _ctx ?yield-fn]
  (let [{: agent : task : cwd} args]
    (if (or (not agent) (= agent ""))
        (result "missing 'agent'" true)
        (or (not task) (= task ""))
        (result "missing 'task'" true)
        (let [requested-cwd (if (and cwd (not= cwd "")) cwd (path.cwd))
              launch-cwd (absolute-cwd requested-cwd)]
          (if (not (path.dir-exists? launch-cwd))
              (result (.. "cwd does not exist: " requested-cwd) true)
              (let [physical-cwd (path.pwd-physical launch-cwd)]
                (if (not physical-cwd)
                    (result (.. "cwd is not accessible: " requested-cwd) true)
                    (let [(cfg err) (discover.find-agent agent)]
                      (if err
                          (invalid-agent-result agent err)
                          (not cfg)
                          (result (.. "unknown agent: " agent
                                      " (looked in .fen/agents and "
                                      (path.config-dir :fen) "/agents)")
                                  true)
                          (run-agent cfg agent task requested-cwd launch-cwd
                                     physical-cwd ?yield-fn))))))))))

(fn M.register [api]
  (api.register :tool
    {:name :subagent
     :label "Subagent"
     :parallel-safe? true
     :parallel-cap 4
     :snippet "Delegate a task to a child fen agent with isolated context"
     :description (.. "Delegate a focused task to a named child agent running in "
                      "a fresh fen process with its own context window. Use this "
                      "to keep long or self-contained work (research, a scoped "
                      "edit, a review pass) out of the main conversation. The "
                      "child returns only its final text. When several "
                      "independent delegated tasks are useful, emit multiple "
                      "subagent tool calls in the same assistant turn; fen may "
                      "run them concurrently, capped at 4. Agents are defined "
                      "as markdown files under .fen/agents/ (project) or "
                      "~/.config/fen/agents/ (user).")
     :parameters {:type :object
                  :properties {:agent {:type :string
                                       :description "Name of the agent to run (the .md filename without extension)."}
                               :task {:type :string
                                      :description "The task/prompt to hand to the child agent."}
                               :cwd {:type :string
                                     :description "Working directory for the child; validated to exist. Defaults to the current directory."}}
                  :required [:agent :task]}
     :execute execute})
  true)

M
