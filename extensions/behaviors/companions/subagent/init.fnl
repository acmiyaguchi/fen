;; subagent tool — delegate a focused task to a child fen process.
;;
;; Out-of-process by design (see issue #16): the child is a fresh `fen` with its
;; own context window, an agent-specific system prompt, and explicit model/
;; provider routing. By default it inherits the parent agent's provider/model
;; when the tool context exposes them; agent frontmatter can override either,
;; with provider-only intentionally omitting the inherited model. We spawn it
;; with the json presenter writing a structured
;; result blob to a temp file (FEN_JSON_OUTPUT_PATH), then return the child's
;; final text or actionable diagnostics plus details to the parent. Cooperative
;; yielding and timeout/abort handling come free from process.run-captured.

(local types (require :fen.core.types))
(local process (require :fen.util.process))
(local runtime (require :fen.runtime))
(local path (require :fen.util.path))
(local json (require :fen.util.json))
(local text (require :fen.util.text))
(local discover (require :fen.extensions.subagent.discover))
(local sub-events (require :fen.extensions.subagent.events))
(local run-state (require :fen.extensions.subagent.state))

(local M {})

(local DEFAULT-TIMEOUT-SECONDS 300)
(local MAX-PROMPT-AGENTS 8)
(local MAX-PROMPT-DESCRIPTION-BYTES 96)

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
  "Read and JSON-decode P. Returns blob plus :ok, or nil plus a status/reason."
  (let [(f err) (io.open p :r)]
    (if (not f)
        (values nil :missing (tostring err))
        (let [data (f:read :*a)]
          (f:close)
          (if (or (not data) (= data ""))
              (values nil :missing "empty JSON output")
              (let [(ok? blob) (pcall json.decode data)]
                (if (and ok? (= (type blob) :table))
                    (values blob :ok nil)
                    ok?
                    (values nil :invalid "decoded JSON is not an object")
                    (values nil :invalid (tostring blob)))))))))

(fn present? [v]
  (and v (not= v "")))

(fn inherited-agent [ctx]
  (and ctx ctx.agent))

(fn effective-routing [cfg ctx]
  "Resolve the child process provider/model policy.

   With no frontmatter override, inherit the parent provider/model when the
   tool context exposes ctx.agent. A model-only override keeps the inherited
   provider and replaces the model. A provider+model override uses both
   frontmatter values. A provider-only override deliberately omits the inherited
   model rather than pairing it with a different provider."
  (let [agent (inherited-agent ctx)
        inherited-provider (and agent agent.provider-name)
        inherited-model (and agent agent.model)
        fm-provider (and (present? cfg.provider) cfg.provider)
        fm-model (and (present? cfg.model) cfg.model)
        provider (or fm-provider inherited-provider)
        provider-source (if fm-provider :frontmatter
                            inherited-provider :inherited
                            :unset)
        provider-override? (present? fm-provider)
        model (if fm-model
                  fm-model
                  provider-override?
                  nil
                  inherited-model)
        model-source (if fm-model :frontmatter
                         provider-override? :omitted-provider-override
                         inherited-model :inherited
                         :unset)]
    {:provider provider
     :model model
     :provider-source provider-source
     :model-source model-source}))

(fn build-argv [bin task sys-path routing]
  (let [argv [bin "--presenter" "json" "--print" task
              "--system-file" sys-path "--no-session"]]
    (each [_ [flag val] (ipairs [["--model" routing.model]
                                 ["--provider" routing.provider]])]
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

(fn blank? [s]
  (or (not s) (= s "")))

(fn add-detail-line [lines label val]
  (when (not= val nil)
    (table.insert lines (.. "- " label ": " (tostring val)))))

(fn summarize-usage [usage]
  (when usage
    (or usage.total-tokens
        usage.total_tokens
        (and (or usage.input usage.output)
             (.. "input=" (tostring usage.input)
                 " output=" (tostring usage.output))))))

(fn diagnostic-text [summary details ?child-text]
  (let [lines [summary]]
    (add-detail-line lines "run id" details.run-id)
    (add-detail-line lines "agent" details.agent)
    (add-detail-line lines "requested cwd" details.requested-cwd)
    (add-detail-line lines "cwd" details.cwd)
    (add-detail-line lines "physical cwd" details.physical-cwd)
    (add-detail-line lines "provider" details.provider)
    (add-detail-line lines "provider source" details.provider-source)
    (add-detail-line lines "model" details.model)
    (add-detail-line lines "model source" details.model-source)
    (add-detail-line lines "exit code" details.exit-code)
    (add-detail-line lines "signal" details.signal)
    (add-detail-line lines "timed out" details.timed-out?)
    (add-detail-line lines "error" details.error)
    (add-detail-line lines "stop reason" details.stop-reason)
    (add-detail-line lines "duration ms" details.duration-ms)
    (add-detail-line lines "json output" details.json-status)
    (add-detail-line lines "json error" details.json-error)
    (add-detail-line lines "event stream" details.event-status)
    (add-detail-line lines "event count" details.event-count)
    (add-detail-line lines "event errors" details.event-error-count)
    (add-detail-line lines "usage" (summarize-usage details.usage))
    (add-detail-line lines "output truncated" details.output-truncated?)
    (add-detail-line lines "full output" details.full-output-path)
    (when (not (blank? ?child-text))
      (table.insert lines (.. "\nChild message:\n" ?child-text)))
    (when (not (blank? details.output-tail))
      (table.insert lines (.. "\nChild output tail:\n" details.output-tail)))
    (table.concat lines "\n")))

(fn cancellation-marker? [err]
  (and (= (type err) :table) (= err.type :cancel-marker)))

(fn append-local-event! [run ev]
  (let [normalized (sub-events.normalize ev {:run-id run.id
                                             :agent run.agent
                                             :requested-cwd run.requested-cwd
                                             :cwd run.cwd
                                             :physical-cwd run.physical-cwd})]
    (run-state.append-event! run.id normalized)
    normalized))

(fn drain-events! [run event-path]
  (let [(events offset errors status) (sub-events.drain event-path run.event-offset)]
    (run-state.set-event-offset! run.id offset)
    (each [_ ev (ipairs events)]
      (run-state.append-event! run.id ev))
    (each [_ err (ipairs errors)]
      (run-state.append-event-error! run.id err))
    status))

(fn event-error-count [run]
  (length (or run.event-errors [])))

(fn event-details [run status]
  {:event-status status
   :event-count (or run.event-count 0)
   :event-error-count (event-error-count run)})

(fn run-agent [cfg agent task requested-cwd cwd physical-cwd ctx ?yield-fn]
  (let [bin (runtime.binary-path)]
    (if (not bin)
        (result "cannot resolve fen binary to spawn subagent" true)
        (let [sys-path (write-temp cfg.body)]
          (if (not sys-path)
              (result "cannot stage subagent system prompt" true)
              (let [out-path (os.tmpname)
                    event-path (os.tmpname)
                    child-task (task-with-cwd-context task requested-cwd cwd physical-cwd)
                    routing (effective-routing cfg ctx)
                    argv (build-argv bin child-task sys-path routing)
                    timeout-seconds (or cfg.timeout-seconds
                                        DEFAULT-TIMEOUT-SECONDS)
                    run (run-state.start! {:agent agent
                                           :task task
                                           :requested-cwd requested-cwd
                                           :cwd cwd
                                           :physical-cwd physical-cwd
                                           :timeout-seconds timeout-seconds})]
                (append-local-event! run {:type :subagent-start
                                          :task task
                                          :timeout-seconds timeout-seconds})
                (let []
                  (var last-event-status :not-read)
                  (let [yield-with-events (fn []
                                            (set last-event-status
                                                 (drain-events! run event-path))
                                            (when ?yield-fn (?yield-fn))
                                            (set last-event-status
                                                 (drain-events! run event-path)))
                        (ok? r-or-err) (pcall
                                        (fn []
                                          (process.run-captured
                                            {:argv argv
                                             :cwd cwd
                                             :env {:FEN_JSON_OUTPUT_PATH out-path
                                                   :FEN_SUBAGENT_EVENT_PATH event-path
                                                   :FEN_SUBAGENT_RUN_ID run.id
                                                   :FEN_SUBAGENT_NAME (tostring agent)
                                                   :FEN_SUBAGENT_REQUESTED_CWD requested-cwd
                                                   :FEN_SUBAGENT_CWD cwd
                                                   :FEN_SUBAGENT_PHYSICAL_CWD physical-cwd
                                                   :PWD cwd}
                                             :timeout-seconds timeout-seconds
                                             :spill? true}
                                            yield-with-events)))]
                  (set last-event-status (drain-events! run event-path))
                  (if (not ok?)
                      (do
                        (os.remove sys-path)
                        (os.remove out-path)
                        (os.remove event-path)
                        (let [cancelled? (cancellation-marker? r-or-err)
                              base-details {:run-id run.id
                                            :agent agent
                                            :requested-cwd requested-cwd
                                            :cwd cwd
                                            :physical-cwd physical-cwd
                                            :provider routing.provider
                                            :model routing.model
                                            :provider-source routing.provider-source
                                            :model-source routing.model-source
                                            :error (text.first-line (tostring r-or-err))}
                              extra (event-details run last-event-status)
                              details (do
                                        (each [k v (pairs extra)]
                                          (tset base-details k v))
                                        base-details)]
                          (append-local-event! run {:type :subagent-done
                                                    :status (if cancelled?
                                                                :cancelled
                                                                :failed)
                                                    :summary details.error})
                          (run-state.finish! run.id (if cancelled? :cancelled :failed)
                                             details)
                          (if cancelled?
                              (error r-or-err)
                              (result (diagnostic-text "Subagent failed before producing a result."
                                                       details nil)
                                      true details))))
                      (let [r r-or-err
                            (decoded json-status json-error) (decode-file out-path)
                            parsed (or decoded {})]
                        (os.remove sys-path)
                        (os.remove out-path)
                        (os.remove event-path)
                        (let [child-text (or parsed.final-text parsed.error "")
                              failure? (or (not= r.exit-code 0) r.signal r.timed-out?
                                           (not decoded) (= parsed.stop-reason :error))
                              empty-final? (and decoded (not failure?)
                                                (blank? parsed.final-text))
                              status (if r.timed-out?
                                         :timed-out
                                         failure?
                                         :failed
                                         :completed)]
                          (append-local-event! run {:type :subagent-done
                                                    :status status
                                                    :summary child-text})
                          (let [details {:run-id run.id
                                         :agent agent
                                         :requested-cwd requested-cwd
                                         :cwd cwd
                                         :physical-cwd physical-cwd
                                         :provider routing.provider
                                         :model routing.model
                                         :provider-source routing.provider-source
                                         :model-source routing.model-source
                                         :usage parsed.usage
                                         :stop-reason parsed.stop-reason
                                         :duration-ms r.duration-ms
                                         :timed-out? r.timed-out?
                                         :exit-code r.exit-code
                                         :signal r.signal
                                         :json-status json-status
                                         :json-error json-error
                                         :empty-final-text? empty-final?
                                         :output-tail r.output
                                         :output-truncated? r.truncated?
                                         :full-output-path r.full-output-path}
                                extra (event-details run last-event-status)]
                            (each [k v (pairs extra)]
                              (tset details k v))
                            (let [text (if failure?
                                           (diagnostic-text "Subagent failed." details child-text)
                                           empty-final?
                                           (diagnostic-text "Subagent completed with empty final text."
                                                            details nil)
                                           child-text)]
                              (run-state.finish! run.id status details)
                              (result text failure? details))))))))))))))

(fn invalid-agent-result [agent err]
  (result (.. "invalid agent definition " err.file ": " err.reason) true
          {:agent agent :path err.file :reason err.reason}))

(fn trim [s]
  (text.trim (tostring (or s ""))))

(fn fit [s w]
  (let [s (tostring (or s ""))]
    (if (> (length s) w)
        (if (> w 1) (.. (string.sub s 1 (- w 1)) "…") "…")
        s)))

(fn pad [s w]
  (let [s (fit s w)
        n (length s)]
    (.. s (string.rep " " (math.max 0 (- w n))))))

(fn agent-key [agent]
  (tostring (or agent.key agent.name "")))

(fn sorted-agents []
  (let [agents []]
    (each [_ a (ipairs (or (discover.list) []))]
      (table.insert agents a))
    (table.sort agents
      (fn [a b]
        (< (agent-key a) (agent-key b))))
    agents))

(fn provider-model-status [agent]
  (let [provider (trim agent.provider)
        model (trim agent.model)]
    (if (and (= provider "") (= model ""))
        "inherit"
        (.. (if (= provider "") "inherit" provider)
            "/"
            (if (= model "") "default" model)))))

(fn timeout-status [agent]
  (let [seconds (or agent.timeout-seconds DEFAULT-TIMEOUT-SECONDS)]
    (.. (tostring seconds) "s" (if agent.timeout-seconds "" " default"))))

(fn roots []
  (if (= (type discover.roots) :function)
      (or (discover.roots) [])
      []))

(fn roots-lines []
  (let [lines []
        rs (roots)]
    (if (= (length rs) 0)
        (table.insert lines "No subagent roots configured.")
        (do
          (table.insert lines "Searched roots:")
          (each [_ r (ipairs rs)]
            (table.insert lines (.. "- " (tostring (or r.scope :unknown))
                                    ": " (tostring (or r.path "")))))))
    lines))

(fn find-agent-in-list [agents name]
  (let [wanted (tostring (or name ""))]
    (var found nil)
    (each [_ a (ipairs agents)]
      (when (and (not found) (= (agent-key a) wanted))
        (set found a)))
    found))

(fn render-agents-list [agents ?filter]
  (let [filter (trim ?filter)
        shown []]
    (if (= filter "")
        (each [_ a (ipairs agents)]
          (table.insert shown a))
        (let [found (find-agent-in-list agents filter)]
          (when found (table.insert shown found))))
    (let [lines [(.. "# Subagents (" (length shown) " shown, "
                     (length agents) " discovered)")
                 ""]]
      (if (= (length agents) 0)
          (do
            (table.insert lines "No subagents discovered.")
            (each [_ line (ipairs (roots-lines))]
              (table.insert lines line))
            (table.insert lines "")
            (table.insert lines "Add project agents under .fen/agents/ or user agents under the configured fen agents directory."))
          (= (length shown) 0)
          (table.insert lines (.. "No subagent named `" filter "`."))
          (do
            (table.insert lines "```text")
            (table.insert lines (.. (pad "name" 24) " "
                                    (pad "scope" 8) " "
                                    (pad "provider/model" 24) " "
                                    (pad "timeout" 12) " description"))
            (table.insert lines (.. (pad "----" 24) " "
                                    (pad "-----" 8) " "
                                    (pad "--------------" 24) " "
                                    (pad "-------" 12) " -----------"))
            (each [_ a (ipairs shown)]
              (table.insert lines
                (.. (pad (agent-key a) 24) " "
                    (pad (tostring (or a.scope :unknown)) 8) " "
                    (pad (provider-model-status a) 24) " "
                    (pad (timeout-status a) 12) " "
                    (fit (or a.description "") 72))))
            (table.insert lines "```")))
      (table.concat lines "\n"))))

(fn agents-command-complete [_arg-prefix _ctx]
  (let [out []]
    (each [_ a (ipairs (sorted-agents))]
      (table.insert out {:label (agent-key a)
                         :value (agent-key a)
                         :description (or a.description
                                          (tostring (or a.scope "")))}))
    out))

(fn agents-command-handler [args _ctx api]
  (api.emit {:type :assistant-text
             :text (render-agents-list (sorted-agents) args)}))

(fn duration-ms [run]
  (or run.duration-ms
      (and (= run.status :running)
           (* 1000 (math.max 0 (os.difftime (os.time) run.started-at))))))

(fn duration-label [run]
  (let [ms (duration-ms run)]
    (if (not ms)
        "-"
        (< ms 1000)
        (.. (tostring ms) "ms")
        (.. (tostring (math.floor (/ ms 1000))) "s"))))

(fn render-run-table [runs]
  (let [lines ["```text"
               (.. (pad "id" 12) " "
                   (pad "agent" 16) " "
                   (pad "status" 10) " "
                   (pad "duration" 8) " "
                   (pad "cwd" 24) " task")
               (.. (pad "--" 12) " "
                   (pad "-----" 16) " "
                   (pad "------" 10) " "
                   (pad "--------" 8) " "
                   (pad "---" 24) " ----")]]
    (each [_ r (ipairs runs)]
      (table.insert lines
        (.. (pad r.id 12) " "
            (pad r.agent 16) " "
            (pad (tostring r.status) 10) " "
            (pad (duration-label r) 8) " "
            (pad (or r.cwd "") 24) " "
            (fit (or r.task-summary "") 72))))
    (table.insert lines "```")
    (table.concat lines "\n")))

(fn latest-runs []
  (let [runs (run-state.runs)
        out []
        seen {}
        active (run-state.active-runs)
        start (math.max 1 (- (length runs) 9))]
    (each [_ run (ipairs active)]
      (table.insert out run)
      (tset seen run.id true))
    (for [i start (length runs)]
      (let [run (. runs i)]
        (when (and run (not (. seen run.id)))
          (table.insert out run)
          (tset seen run.id true))))
    out))

(fn event-label [ev]
  (let [typ (tostring (or ev.type "event"))
        summary (or ev.summary ev.error ev.name "")]
    (if (= (tostring summary) "") typ (.. typ ": " (fit summary 96)))))

(fn append-event-tail! [lines runs]
  (var any? false)
  (each [_ r (ipairs runs)]
    (let [events (or r.events [])]
      (when (> (length events) 0)
        (when (not any?)
          (set any? true)
          (table.insert lines "")
          (table.insert lines "Latest events:"))
        (let [last (. events (length events))]
          (table.insert lines (.. "- " r.id " " (event-label last)))))))
  any?)

(fn render-subagent-runs []
  (let [active-count (run-state.active-count)
        runs (latest-runs)
        lines [(.. "# Subagent runs (" active-count " active)") ""]]
    (if (= (length runs) 0)
        (table.insert lines "No subagent runs recorded yet.")
        (do
          (table.insert lines (render-run-table runs))
          (append-event-tail! lines runs)))
    (table.insert lines "")
    (table.insert lines "The current `subagent` tool call is still blocking: results are collected when the child exits.")
    (table.insert lines "Use `/subagents cancel` to request cancellation for active child processes in the current turn.")
    (table.concat lines "\n")))

(fn subagents-command-handler [args ctx api]
  (let [cmd (string.lower (or (string.match (trim args) "^(%S+)") ""))]
    (if (= cmd "cancel")
        (let [n (run-state.active-count)]
          (if (= n 0)
              (api.emit {:type :assistant-text
                         :text "No active subagent runs to cancel."})
              (do
                (when ctx
                  (set ctx.cancel-requested? true))
                (api.emit {:type :assistant-text
                           :text (.. "Requested cancellation for " n
                                     " active subagent run(s) in the current turn.")}))))
        (api.emit {:type :assistant-text
                   :text (render-subagent-runs)}))))

(fn subagent-status-render [_ctx]
  (let [n (run-state.active-count)]
    (when (> n 0)
      {:text (.. "subagent:" n " running")
       :style :status})))

(fn subagent-snapshot [_ctx]
  (run-state.snapshot))

(fn tool-visible? [ctx name]
  (var found? false)
  (each [_ tool (ipairs (or (?. ctx :tools) []))]
    (when (= (tostring tool.name) (tostring name))
      (set found? true)))
  found?)

(fn agents-prompt-fragment [ctx]
  (when (tool-visible? ctx :subagent)
    (let [agents (sorted-agents)]
      (when (> (length agents) 0)
        (let [lines ["Available subagents for the `subagent` tool:"]
              limit (math.min (length agents) MAX-PROMPT-AGENTS)]
          (for [i 1 limit]
            (let [a (. agents i)]
              (table.insert lines (.. "- " (agent-key a) ": "
                                      (fit (or a.description "")
                                           MAX-PROMPT-DESCRIPTION-BYTES)))))
          (when (> (length agents) limit)
            (table.insert lines (.. "- ... " (- (length agents) limit)
                                    " more; run /agents for details")))
          (table.concat lines "\n"))))))

(fn execute [args ctx ?yield-fn]
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
                                      " (looked in project, user, and bundled agents)")
                                  true)
                          (run-agent cfg agent task requested-cwd launch-cwd
                                     physical-cwd ctx ?yield-fn))))))))))

(fn M.register [api]
  (api.prompt agents-prompt-fragment
              {:order 62
               :id :available-subagents
               :title "Available subagents"
               :description "Discovered subagents that can be invoked with the subagent tool."})
  (api.register :command
    {:name :agents
     :order 66
     :description "List discovered subagents and their model/timeout metadata"
     :complete agents-command-complete
     :handler (fn [args ctx] (agents-command-handler args ctx api))})
  (api.register :command
    {:name :subagents
     :order 67
     :description "Show active/recent subagent runs; use `/subagents cancel` to cancel active children"
     :handler (fn [args ctx] (subagents-command-handler args ctx api))})
  (api.register :status
    {:name :subagent
     :side :left
     :order 36
     :render subagent-status-render})
  (api.register :introspect
    {:name :state
     :description "Current subagent run state and recent child processes"
     :snapshot subagent-snapshot})
  (api.register :tool
    {:name :subagent
     :label "Subagent"
     :parallel-safe? true
     :parallel-cap 4
     :snippet "Delegate a task to a child fen agent with isolated context"
     :description (.. "Delegate a focused task to a named child agent running in "
                      "a fresh fen process with its own context window. By "
                      "default the child inherits the parent provider/model "
                      "when available; agent frontmatter may override model, "
                      "provider, or both. A provider-only override passes only "
                      "that provider and intentionally omits the parent model. "
                      "Use this to keep long or self-contained work (research, "
                      "a scoped edit, a review pass) out of the main "
                      "conversation. The child normally returns final text; "
                      "failures and empty successful results return diagnostic "
                      "text with details, including provider/model sources. "
                      "When several "
                      "subagent tool calls in the same assistant turn; fen may "
                      "run them concurrently, capped at 4. Agents are defined "
                      "as markdown files under .fen/agents/ (project), "
                      "~/.config/fen/agents/ (user), or bundled with fen.")
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
