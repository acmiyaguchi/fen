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
(local MAX-STEERING-RESTARTS 3)
(local MAX-BACKGROUND-RUNS 4)
(local PARTIAL-EVENT-TAIL 6)

;; Persistent state survives /reload, so add newly introduced operations to an
;; older live module table before registration uses them. Fresh processes get
;; the same implementations directly from state.fnl.
(when (not run-state.clear!)
  (set run-state.clear!
       (fn []
         (set run-state._state.runs [])
         (set run-state._state.active {})
         (set run-state._state.jobs {})
         nil)))

(when (not run-state.remove!)
  (set run-state.remove!
       (fn [id]
         (if (. run-state._state.active id)
             (values nil "run is active")
             (let []
               (var removed nil)
               (var found nil)
               (each [i run (ipairs run-state._state.runs)]
                 (when (and (not found) (= run.id id))
                   (set found i)
                   (set removed run)))
               (when found (table.remove run-state._state.runs found))
               (values removed (and (not removed) "run not found")))))))

(when (not run-state.reconcile-background!)
  (set run-state.reconcile-background!
       (fn []
         (let [stale []]
           (each [id run (pairs run-state._state.active)]
             (when (and run.background?
                        (not (. run-state._state.jobs id)))
               (table.insert stale id)))
           (each [_ id (ipairs stale)]
             (run-state.finish! id :failed
                                {:error "background subagent lost its process handle"}))
           (each [id _job (pairs run-state._state.jobs)]
             (when (not (. run-state._state.active id))
               (tset run-state._state.jobs id nil)))
           (length stale)))))

;; Canonical token fields, in display order. `total-tokens` conventionally
;; excludes cache tokens (input+output), matching provider adapters.
(local USAGE-FIELDS [:input :output :cache-read :cache-write :reasoning
                     :total-tokens])

(fn usage-num [v] (and (= (type v) :number) v))

(fn usage-pick [usage keys]
  (var found nil)
  (each [_ k (ipairs keys)]
    (when (= found nil)
      (let [v (usage-num (. usage k))]
        (when v (set found v)))))
  found)

(fn canonical-usage [usage]
  "Extract canonical token fields from a provider usage table, tolerating both
   Fennel-cased and provider snake_case keys. Non-token fields such as
   latency-ms are ignored. Returns nil when nothing usable is present."
  (when (= (type usage) :table)
    (let [input (usage-pick usage [:input :input_tokens :input-tokens
                                   :prompt_tokens :prompt-tokens])
          output (usage-pick usage [:output :output_tokens :output-tokens
                                    :completion_tokens :completion-tokens])
          cache-read (usage-pick usage [:cache-read :cache_read :cached_tokens
                                        :cache_read_input_tokens])
          cache-write (usage-pick usage [:cache-write :cache_write
                                         :cache_creation_input_tokens])
          reasoning (usage-pick usage [:reasoning :reasoning_tokens
                                       :reasoning-tokens])
          reported-total (usage-pick usage [:total-tokens :total_tokens :total])
          total (or reported-total
                    (when (or input output)
                      (+ (or input 0) (or output 0))))
          out {}]
      (when input (set out.input input))
      (when output (set out.output output))
      (when cache-read (set out.cache-read cache-read))
      (when cache-write (set out.cache-write cache-write))
      (when reasoning (set out.reasoning reasoning))
      (when total (set out.total-tokens total))
      (when (next out) out))))

(fn explicit-total? [usage]
  (and (= (type usage) :table)
       (not= nil (usage-pick usage [:total-tokens :total_tokens :total]))))

(fn usage-provenance-of [usage ?source]
  "Per-field provenance for a usage table. Reported fields take ?source; a total
   derived from input+output is flagged :estimated."
  (let [canon (canonical-usage usage)
        source (or ?source :provider-reported)
        prov {}]
    (when canon
      (each [k _ (pairs canon)] (tset prov k source))
      (when (and (. canon :total-tokens) (not (explicit-total? usage)))
        (tset prov :total-tokens :estimated)))
    prov))

(fn subtract-usage [a b]
  (let [out {}]
    (each [_ k (ipairs USAGE-FIELDS)]
      (let [d (- (or (and a (. a k)) 0) (or (and b (. b k)) 0))]
        (when (> d 0) (tset out k d))))
    out))

(fn add-usage [a b]
  (let [out {}]
    (each [_ k (ipairs USAGE-FIELDS)]
      (let [s (+ (or (and a (. a k)) 0) (or (and b (. b k)) 0))]
        (when (> s 0) (tset out k s))))
    out))

(fn merge-provenance [prior blob-prov fields]
  (let [out {}]
    (each [k _ (pairs (or fields {}))]
      (let [p (or (. blob-prov k) (. prior k) :provider-reported)]
        (tset out k (if (or (= (. blob-prov k) :estimated)
                            (= (. prior k) :estimated))
                        :estimated
                        p))))
    out))

(fn copy-usage-table [t]
  (let [out {}]
    (when (= (type t) :table) (each [k v (pairs t)] (tset out k v)))
    out))

;; state.fnl stays out of reload to preserve live run records, so patch newly
;; introduced usage operations onto an older live module table too. Fresh
;; processes get the same implementations directly from state.fnl.
(when (not run-state.canonical-usage)
  (set run-state.canonical-usage canonical-usage))

(when (not run-state.usage-provenance)
  (set run-state.usage-provenance usage-provenance-of))

(fn shim-find-run [id]
  (let [st run-state._state]
    (or (. st.active id)
        (let []
          (var found nil)
          (each [_ r (ipairs st.runs)]
            (when (and (not found) (= r.id id)) (set found r)))
          found))))

(when (not run-state.accumulate-usage!)
  (set run-state.accumulate-usage!
       (fn [id usage ?source]
         (let [run (shim-find-run id)
               canon (canonical-usage usage)]
           (when (and run canon)
             (when (= run.usage-acc nil)
               (set run.usage-acc {:totals {} :current {} :provenance {}
                                   :turns 0 :source :events}))
             (let [acc run.usage-acc
                   source (or ?source :provider-reported)
                   prov (usage-provenance-of usage source)]
               (set acc.turns (+ (or acc.turns 0) 1))
               (each [k v (pairs canon)]
                 (tset acc.totals k (+ (or (. acc.totals k) 0) v))
                 (tset acc.current k (+ (or (. acc.current k) 0) v))
                 (let [new-prov (. prov k) old-prov (. acc.provenance k)]
                   (tset acc.provenance k
                         (if (or (= new-prov :estimated) (= old-prov :estimated))
                             :estimated
                             :provider-reported))))))
           run))))

(when (not run-state.seal-usage-attempt!)
  (set run-state.seal-usage-attempt!
       (fn [id]
         (let [run (shim-find-run id)]
           (when (and run run.usage-acc) (set run.usage-acc.current {}))
           run))))

(fn apply-usage-telemetry! [run details]
  "Reconcile event-derived accumulation with an authoritative final-result
   usage blob without double counting, then stamp usage fields onto DETAILS.

   The final blob is the last child attempt's cumulative total, and the sum of
   that attempt's per-turn :llm-end usage duplicates it, so for the final
   attempt we prefer the authoritative blob. Earlier steered/restarted attempts
   have no surviving blob, so their sealed event totals (cumulative minus the
   in-flight attempt) are added back. Kept in this reloadable module so
   telemetry survives /reload against durable state."
  (let [acc run.usage-acc
        blob (canonical-usage details.usage)]
    (if blob
        (let [prior (subtract-usage (and acc acc.totals) (and acc acc.current))
              merged (add-usage prior blob)
              blob-prov (usage-provenance-of details.usage :provider-reported)
              prov (merge-provenance (or (and acc acc.provenance) {})
                                     blob-prov merged)]
          (set details.usage merged)
          (set details.usage-provenance prov)
          ;; :mixed when earlier attempts contributed event-only usage.
          (set details.usage-source (if (next prior) :mixed :final-result))
          (set details.usage-complete? true))
        (and acc acc.totals (next acc.totals))
        (do
          (set details.usage (copy-usage-table acc.totals))
          (set details.usage-provenance (copy-usage-table acc.provenance))
          (set details.usage-source :events)
          (set details.usage-complete? false))
        (do
          (set details.usage nil)
          (set details.usage-source nil)))
    (when acc (set details.usage-turns acc.turns))
    details))

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
    (add-detail-line lines "timeout seconds" details.timeout-seconds)
    (add-detail-line lines "json output" details.json-status)
    (add-detail-line lines "json error" details.json-error)
    (add-detail-line lines "event stream" details.event-status)
    (add-detail-line lines "event count" details.event-count)
    (add-detail-line lines "event errors" details.event-error-count)
    (add-detail-line lines "restart count" details.restart-count)
    (add-detail-line lines "steering notes" details.steering-count)
    (add-detail-line lines "usage" (summarize-usage details.usage))
    (add-detail-line lines "output truncated" details.output-truncated?)
    (add-detail-line lines "full output" details.full-output-path)
    (add-detail-line lines "partial progress" details.partial-progress?)
    (add-detail-line lines "partial assistant text" details.partial-assistant-text?)
    (when (not (blank? details.event-tail))
      (table.insert lines (.. "\nLatest child progress:\n" details.event-tail)))
    (when (and details.timed-out? details.partial-progress?)
      (table.insert lines "\nNext action: continue from the progress above, or retry with a narrower task and an explicit timeout-seconds budget."))
    (when (not (blank? ?child-text))
      (table.insert lines (.. "\nChild message:\n" ?child-text)))
    (when (not (blank? details.output-tail))
      (table.insert lines (.. "\nChild output tail:\n" details.output-tail)))
    (table.concat lines "\n")))

(fn cancellation-marker? [err]
  (and (= (type err) :table) (= err.type :cancel-marker)))

(fn steering-marker? [err]
  (and (= (type err) :table) (= err.type :subagent-steer)))

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
      (run-state.append-event! run.id ev)
      ;; Fold completed-turn usage into durable totals as it arrives, so timed
      ;; out or killed children retain usage even without a final result blob.
      (when (and (= ev.type :llm-end) ev.usage)
        (run-state.accumulate-usage! run.id ev.usage)))
    (each [_ err (ipairs errors)]
      (run-state.append-event-error! run.id err))
    status))

(fn drain-all! [run event-path]
  "Drain every complete record before a terminal or restart transition, so a
   burst of late :llm-end usage is not lost to the bounded per-call batch."
  (var status (drain-events! run event-path))
  (var prev nil)
  (var guard 0)
  (while (and (= status :ok) (not= run.event-offset prev) (< guard 10000))
    (set prev run.event-offset)
    (set status (drain-events! run event-path))
    (set guard (+ guard 1)))
  status)

(fn event-error-count [run]
  (length (or run.event-errors [])))

(fn event-label [ev]
  (let [typ (tostring (or ev.type :event))
        name (and ev.name (.. " " (tostring ev.name)))
        summary (or ev.summary ev.error "")]
    (.. "- " typ (or name "")
        (if (blank? summary) "" (.. ": " summary)))))

(fn partial-event-details [run]
  (let [events (or run.events [])
        lines []]
    (var partial-assistant-text? (not (not run.partial-assistant-text?)))
    (var useful-count 0)
    (each [_ ev (ipairs events)]
      (when (or (= ev.type :assistant-text)
                (= ev.type :assistant-text-delta))
        (set partial-assistant-text? true)))
    (var i (math.max 1 (+ 1 (- (length events) PARTIAL-EVENT-TAIL))))
    (while (<= i (length events))
      (let [ev (. events i)]
        (when (not (or (= ev.type :subagent-start)
                       (= ev.type :subagent-done)
                       (= ev.type :agent-started)
                       (= ev.type :llm-start)
                       (= ev.type :llm-end)))
          (set useful-count (+ useful-count 1))
          (table.insert lines (event-label ev))))
      (set i (+ i 1)))
    {:partial-progress? (> useful-count 0)
     :partial-assistant-text? partial-assistant-text?
     :event-tail (and (> (length lines) 0) (table.concat lines "\n"))}))

(fn event-details [run status]
  (let [details {:event-status status
                 :event-count (or run.event-count 0)
                 :event-error-count (event-error-count run)
                 :restart-count (or run.restart-count 0)
                 :steering-count (length (or run.steering-notes []))}
        progress-details (partial-event-details run)]
    (each [k v (pairs progress-details)]
      (tset details k v))
    details))

(fn steering-task [task note]
  (.. task "\n\nSteering note for restarted subagent run:\n" note))

(fn run-agent [cfg agent task requested-cwd cwd physical-cwd ctx ?yield-fn]
  (let [bin (runtime.binary-path)]
    (if (not bin)
        (result "cannot resolve fen binary to spawn subagent" true)
        (let [sys-path (write-temp cfg.body)]
          (if (not sys-path)
              (result "cannot stage subagent system prompt" true)
              (let [out-path (os.tmpname)
                    event-path (os.tmpname)
                    routing (effective-routing cfg ctx)
                    timeout-seconds (or cfg.timeout-seconds
                                        DEFAULT-TIMEOUT-SECONDS)
                    started-at-ms (process.monotonic-ms)
                    deadline-ms (+ started-at-ms (* timeout-seconds 1000))
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
                  (var current-task task)
                  (var ok? nil)
                  (var r-or-err nil)
                  (var done? false)
                  (fn check-steering! []
                    (let [note (run-state.take-steering! run.id)]
                      (when note
                        (if (< (or run.restart-count 0) MAX-STEERING-RESTARTS)
                            (error {:type :subagent-steer :note note.note :source note.source})
                            (append-local-event! run {:type :steering-rejected
                                                      :summary note.summary})))))
                  (fn yield-with-events []
                    (set last-event-status (drain-events! run event-path))
                    (check-steering!)
                    (when ?yield-fn (?yield-fn))
                    (set last-event-status (drain-events! run event-path))
                    (check-steering!))
                  (while (not done?)
                    (os.remove out-path)
                    (let [remaining-timeout (math.max 0.001
                                                       (/ (- deadline-ms
                                                             (process.monotonic-ms))
                                                          1000))
                          child-task (task-with-cwd-context current-task requested-cwd cwd physical-cwd)
                          argv (build-argv bin child-task sys-path routing)
                          (attempt-ok? attempt-result) (pcall
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
                                                              :timeout-seconds remaining-timeout
                                                              :spill? true}
                                                             yield-with-events)))]
                      (set last-event-status (drain-all! run event-path))
                      (if (and (not attempt-ok?) (steering-marker? attempt-result))
                          (if (< (process.monotonic-ms) deadline-ms)
                              (do
                                (run-state.note-restart! run.id)
                                ;; Seal this attempt so its final blob (if any)
                                ;; reconciles only against its own turns.
                                (run-state.seal-usage-attempt! run.id)
                                (append-local-event! run {:type :subagent-restart
                                                          :summary attempt-result.note})
                                (set current-task (steering-task task attempt-result.note)))
                              (do
                                (set ok? true)
                                (set r-or-err {:exit-code nil
                                               :timed-out? true
                                               :duration-ms (- (process.monotonic-ms)
                                                               started-at-ms)
                                               :output ""
                                               :truncated? false})
                                (set done? true)))
                          (do
                            (set ok? attempt-ok?)
                            (set r-or-err attempt-result)
                            (set done? true)))))
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
                                            :timeout-seconds timeout-seconds
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
                          (apply-usage-telemetry! run details)
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
                                         :timeout-seconds timeout-seconds
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
                              (apply-usage-telemetry! run details)
                              (run-state.finish! run.id status details)
                              (result text failure? details)))))))))))))
(fn remove-job-paths! [job ?keep-full-path]
  (each [_ p (ipairs [job.sys-path job.out-path job.event-path])]
    (when p (os.remove p)))
  (when (and job.full-output-path (not ?keep-full-path))
    (os.remove job.full-output-path)))

(fn background-argv-opts [job]
  (let [remaining (math.max 0.001
                            (/ (- job.deadline-ms (process.monotonic-ms)) 1000))
        child-task (.. (task-with-cwd-context job.current-task job.requested-cwd
                                               job.cwd job.physical-cwd)
                       "\n\nBackground authority:\nThis detached job is read-only. Do not edit files or mutate repositories. Return findings to the parent agent, which owns any edits.\n")]
    {:argv (build-argv job.bin child-task job.sys-path job.routing)
     :cwd job.cwd
     :env {:FEN_JSON_OUTPUT_PATH job.out-path
           :FEN_SUBAGENT_EVENT_PATH job.event-path
           :FEN_SUBAGENT_RUN_ID job.id
           :FEN_SUBAGENT_NAME (tostring job.agent)
           :FEN_SUBAGENT_REQUESTED_CWD job.requested-cwd
           :FEN_SUBAGENT_CWD job.cwd
           :FEN_SUBAGENT_PHYSICAL_CWD job.physical-cwd
           :PWD job.cwd}
     :timeout-seconds remaining
     :spill? true}))

(fn start-background-attempt! [job]
  (os.remove job.out-path)
  (set job.handle (process.start-captured (background-argv-opts job))))

(fn completion-summary [run status child-text]
  (let [one-line (text.truncate-line (text.first-line (or child-text "")) 240)]
    (.. "Subagent " run.id " (" run.agent ") " (tostring status)
        (if (blank? one-line) "." (.. ": " one-line))
        " Inspect with /subagents show " run.id ".")))

(fn queue-background-completion! [run status child-text diagnostic]
  (let [steering (require :fen.extensions.steering.service)
        body (if (= run.collect :full)
                 (if (blank? child-text) diagnostic child-text)
                 (completion-summary run status child-text))]
    ;; Queue only: the ordinary turn lifecycle decides when follow-ups start.
    (steering.queue! :follow-up body)))

(fn finalize-background! [job process-result ?error ?suppress-notification]
  (set job.last-event-status (drain-all! job job.event-path))
  (let [(decoded json-status json-error) (decode-file job.out-path)
        parsed (or decoded {})
        r (or process-result {})
        child-text (or parsed.final-text parsed.error "")
        failed-before? (not (not ?error))
        failure? (or failed-before? (not= r.exit-code 0) r.signal r.timed-out?
                     (not decoded) (= parsed.stop-reason :error))
        status (if r.cancelled? :cancelled
                   r.timed-out? :timed-out
                   failure? :failed
                   :completed)
        details {:run-id job.id
                 :agent job.agent
                 :requested-cwd job.requested-cwd
                 :cwd job.cwd
                 :physical-cwd job.physical-cwd
                 :provider job.routing.provider
                 :model job.routing.model
                 :provider-source job.routing.provider-source
                 :model-source job.routing.model-source
                 :usage parsed.usage
                 :stop-reason parsed.stop-reason
                 :duration-ms (or r.duration-ms
                                  (- (process.monotonic-ms) job.started-at-ms))
                 :timeout-seconds job.timeout-seconds
                 :timed-out? r.timed-out?
                 :exit-code r.exit-code
                 :signal r.signal
                 :json-status json-status
                 :json-error json-error
                 :error (and ?error (text.first-line (tostring ?error)))
                 :output-tail r.output
                 :output-truncated? r.truncated?
                 :result child-text}
        extra (event-details job job.last-event-status)]
    (each [k v (pairs extra)] (tset details k v))
    (let [diagnostic (if failure?
                         (diagnostic-text (if failed-before?
                                             "Subagent failed before producing a result."
                                             "Subagent failed.")
                                          details child-text)
                         child-text)]
      (append-local-event! job {:type :subagent-done
                                :status status
                                :summary child-text})
      (apply-usage-telemetry! job details)
      (run-state.finish! job.id status details)
      (run-state.detach-job! job.id)
      (remove-job-paths! job nil)
      ;; Background inspection uses the decoded result and bounded output tail;
      ;; the raw process spill has no consumer and must not accumulate forever.
      (when r.full-output-path (os.remove r.full-output-path))
      (when (not ?suppress-notification)
        (queue-background-completion! job status child-text diagnostic)))))

(fn restart-background! [job note]
  (run-state.note-restart! job.id)
  ;; Capture the aborted attempt's events, then seal so the next attempt's
  ;; final blob reconciles only against its own turns.
  (set job.last-event-status (drain-all! job job.event-path))
  (run-state.seal-usage-attempt! job.id)
  (append-local-event! job {:type :subagent-restart :summary note})
  (set job.current-task (steering-task job.task note))
  (set job.restart-note nil)
  (start-background-attempt! job))

(fn pump-background-job! [job]
  (set job.last-event-status (drain-events! job job.event-path))
  (when (and (not job.restart-note)
             (< (or job.restart-count 0) MAX-STEERING-RESTARTS))
    (let [note (run-state.take-steering! job.id)]
      (when note
        (set job.restart-note note.note)
        (job.handle:abort))))
  (let [(ok? done? r-or-err) (pcall job.handle.resume job.handle)]
    (if (not ok?)
        (finalize-background! job nil done?)
        done?
        (if (and job.restart-note (< (process.monotonic-ms) job.deadline-ms))
            (let [(restart-ok? restart-err)
                  (pcall restart-background! job job.restart-note)]
              (when (not restart-ok?)
                (finalize-background! job r-or-err restart-err)))
            (finalize-background! job r-or-err nil)))))

(fn pump-background-jobs! []
  (each [_ job (ipairs (run-state.jobs))]
    (pump-background-job! job)))

(fn abort-and-reap! [jobs ?suppress-notification]
  (each [_ job (ipairs jobs)] (job.handle:abort))
  ;; Reap synchronously so callers can safely clear records and temporary
  ;; paths before returning. Bound the drain in case a broken handle does not
  ;; report completion after abort.
  (each [_ job (ipairs jobs)]
    (var done? false)
    (var attempts 0)
    (while (and (not done?) (< attempts 200))
      (set attempts (+ attempts 1))
      (let [(ok? tick-done? r-or-err) (pcall job.handle.resume job.handle)]
        (if (not ok?)
            (do (finalize-background! job nil tick-done?
                                      ?suppress-notification)
                (set done? true))
            tick-done?
            (do (finalize-background! job r-or-err nil
                                      ?suppress-notification)
                (set done? true))
            (process.sleep-ms 5))))
    (when (not done?)
      (finalize-background! job
                            {:exit-code nil :signal nil :cancelled? true
                             :timed-out? false :duration-ms nil :output ""}
                            "child did not exit after cancellation"
                            ?suppress-notification))))

(fn shutdown-background-jobs! [?suppress-notification]
  (abort-and-reap! (run-state.jobs) ?suppress-notification))

(fn launch-background [cfg agent task requested-cwd cwd physical-cwd ctx collect-mode]
  (if (>= (run-state.active-count) MAX-BACKGROUND-RUNS)
      (result "cannot launch background subagent: active run cap (4) reached" true)
      (let [bin (runtime.binary-path)]
        (if (not bin)
            (result "cannot resolve fen binary to spawn subagent" true)
            (let [sys-path (write-temp cfg.body)]
              (if (not sys-path)
                  (result "cannot stage subagent system prompt" true)
                  (let [timeout-seconds (or cfg.timeout-seconds DEFAULT-TIMEOUT-SECONDS)
                        started-at-ms (process.monotonic-ms)
                        run (run-state.start! {:agent agent :task task
                                               :requested-cwd requested-cwd
                                               :cwd cwd :physical-cwd physical-cwd
                                               :timeout-seconds timeout-seconds
                                               :background? true :collect collect-mode})
                        job {:id run.id :agent agent :task task :current-task task
                             :requested-cwd requested-cwd :cwd cwd
                             :physical-cwd physical-cwd :timeout-seconds timeout-seconds
                             :started-at-ms started-at-ms
                             :deadline-ms (+ started-at-ms (* timeout-seconds 1000))
                             :bin bin :sys-path sys-path :out-path (os.tmpname)
                             :event-path (os.tmpname) :routing (effective-routing cfg ctx)
                             :cfg cfg :collect collect-mode :last-event-status :not-read}]
                    (append-local-event! run {:type :subagent-start :task task
                                              :timeout-seconds timeout-seconds})
                    (let [(ok? err) (pcall start-background-attempt! job)]
                      (if (not ok?)
                          (do
                            (run-state.attach-job! run.id job)
                            (finalize-background! job nil err true)
                            (result (.. "cannot start background subagent: "
                                        (text.first-line (tostring err))) true))
                          (do
                            (run-state.attach-job! run.id job)
                            (result (.. "Background subagent started: " run.id)
                                    false {:run-id run.id :background? true
                                           :collect collect-mode})))))))))))

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
    (table.insert lines "Blocking is the default; set `background: true` to return immediately with a run id.")
    (table.insert lines "Background completions are queued as follow-ups and do not start a turn automatically.")
    (table.insert lines "Use `/subagents show RUN_ID` to inspect a stored result and details.")
    (table.insert lines "Use `/subagents usage [RUN_ID]` to see token usage per run and workflow totals.")
    (table.insert lines "Use `/subagents steer RUN_ID NOTE` to restart an active child with steering context.")
    (table.insert lines "Use `/subagents cancel RUN_ID` to abort a detached child, or `/subagents cancel` for all active runs.")
    (table.concat lines "\n")))

(fn human-tokens [n]
  (if (not (= (type n) :number))
      "-"
      (>= n 1000)
      (.. (tostring (math.floor (+ 0.5 (/ n 1000)))) "k")
      (tostring n)))

(fn run-usage-view [run]
  "Return a normalized usage view for a run, preferring the reconciled
   final-result totals in details and falling back to the live accumulator for
   still-running or partially-drained runs. Returns nil when no usage exists."
  (if (and run.details run.details.usage)
      {:usage run.details.usage
       :turns run.details.usage-turns
       :provenance run.details.usage-provenance
       :source run.details.usage-source
       :complete? run.details.usage-complete?}
      (and run.usage-acc run.usage-acc.totals (next run.usage-acc.totals))
      {:usage run.usage-acc.totals
       :turns run.usage-acc.turns
       :provenance run.usage-acc.provenance
       :source (or run.usage-acc.source :events)
       :complete? false}
      nil))

(fn usage-provenance-note [view]
  (let [prov (or view.provenance {})]
    (var estimated? false)
    (each [_ p (pairs prov)]
      (when (= p :estimated) (set estimated? true)))
    (if estimated? "estimated" "provider-reported")))

(fn append-usage-lines! [lines run]
  (let [view (run-usage-view run)]
    (when view
      (table.insert lines "")
      (table.insert lines "Usage:")
      (each [_ key (ipairs USAGE-FIELDS)]
        (let [v (. view.usage key)]
          (when (not= v nil)
            (table.insert lines (.. "- " (tostring key) ": " (tostring v))))))
      (when view.turns
        (table.insert lines (.. "- turns: " (tostring view.turns))))
      (table.insert lines (.. "- source: " (tostring (or view.source :unknown))
                              (if (= view.complete? false) " (partial)" "")))
      (table.insert lines (.. "- provenance: " (usage-provenance-note view))))))

(fn render-run-details [run]
  (if (not run)
      nil
      (let [lines [(.. "# Subagent " run.id)
                   ""
                   (.. "- agent: " run.agent)
                   (.. "- status: " (tostring run.status))
                   (.. "- background: " (tostring (not (not run.background?))))
                   (.. "- collect: " (tostring (or run.collect :summary)))
                   (.. "- cwd: " (or run.cwd ""))
                   (.. "- task: " (or run.task-summary ""))]]
        (when run.details
          (table.insert lines "")
          (table.insert lines "Details:")
          (each [_ key (ipairs [:duration-ms :exit-code :signal :timed-out?
                                :provider :model :stop-reason :event-count
                                :event-error-count :restart-count])]
            (let [v (. run.details key)]
              (when (not= v nil)
                (table.insert lines (.. "- " (tostring key) ": " (tostring v)))))))
        (append-usage-lines! lines run)
        (when (not (blank? run.result))
          (table.insert lines "")
          (table.insert lines "Result:")
          (table.insert lines run.result))
        (table.concat lines "\n"))))

(fn usage-cell [usage key]
  (human-tokens (and usage (. usage key))))

(fn render-usage-table [runs]
  (let [lines ["```text"
               (.. (pad "run" 12) " "
                   (pad "provider" 12) " "
                   (pad "model" 16) " "
                   (pad "status" 10) " "
                   (pad "turns" 6) " "
                   (pad "input" 8) " "
                   (pad "output" 8) " "
                   (pad "cache-r" 8) " "
                   (pad "total" 8) " src")
               (.. (pad "---" 12) " "
                   (pad "--------" 12) " "
                   (pad "-----" 16) " "
                   (pad "------" 10) " "
                   (pad "-----" 6) " "
                   (pad "-----" 8) " "
                   (pad "------" 8) " "
                   (pad "-------" 8) " "
                   (pad "-----" 8) " ---")]
        totals {}
        by-group {}
        group-order []]
    (var any-usage? false)
    (var grand-turns 0)
    (each [_ r (ipairs runs)]
      (let [view (run-usage-view r)
            usage (and view view.usage)
            provider (or (and r.details r.details.provider) "-")
            model (or (and r.details r.details.model) "-")
            status (tostring r.status)]
        (table.insert lines
          (.. (pad r.id 12) " "
              (pad (tostring provider) 12) " "
              (pad (tostring model) 16) " "
              (pad status 10) " "
              (pad (tostring (or (and view view.turns) "-")) 6) " "
              (pad (usage-cell usage :input) 8) " "
              (pad (usage-cell usage :output) 8) " "
              (pad (usage-cell usage :cache-read) 8) " "
              (pad (usage-cell usage :total-tokens) 8) " "
              (if view (tostring (or view.source "-")) "-")))
        (when usage
          (set any-usage? true)
          (each [_ key (ipairs USAGE-FIELDS)]
            (when (. usage key)
              (tset totals key (+ (or (. totals key) 0) (. usage key)))))
          (when (and view view.turns)
            (set grand-turns (+ grand-turns view.turns)))
          (let [gkey (.. (tostring provider) " / " (tostring model) " / " status)
                bucket (or (. by-group gkey)
                           (let [b {:total 0 :turns 0}]
                             (tset by-group gkey b)
                             (table.insert group-order gkey)
                             b))]
            (set bucket.total (+ bucket.total (or (. usage :total-tokens) 0)))
            (set bucket.turns (+ bucket.turns (or (and view view.turns) 0)))))))
    (table.insert lines
      (.. (pad "TOTAL" 12) " "
          (pad "" 12) " "
          (pad "" 16) " "
          (pad "" 10) " "
          (pad (tostring grand-turns) 6) " "
          (pad (usage-cell totals :input) 8) " "
          (pad (usage-cell totals :output) 8) " "
          (pad (usage-cell totals :cache-read) 8) " "
          (pad (usage-cell totals :total-tokens) 8) " "))
    (table.insert lines "```")
    (when (> (length group-order) 0)
      (table.insert lines "")
      (table.insert lines "By provider / model / outcome:")
      (each [_ gkey (ipairs group-order)]
        (let [b (. by-group gkey)]
          (table.insert lines (.. "- " gkey ": " (human-tokens b.total)
                                  " total, " (tostring b.turns) " turns")))))
    (when (not any-usage?)
      (table.insert lines "")
      (table.insert lines "No provider usage recorded for these runs yet."))
    (table.concat lines "\n")))

(fn render-subagent-usage [?run-id]
  (if (present? ?run-id)
      (let [run (run-state.find ?run-id)]
        (or (render-run-details run) (.. "No subagent run named " ?run-id)))
      (let [runs (latest-runs)
            lines [(.. "# Subagent usage (" (length runs) " recent)") ""]]
        (if (= (length runs) 0)
            (table.insert lines "No subagent runs recorded yet.")
            (table.insert lines (render-usage-table runs)))
        (table.concat lines "\n"))))

(fn subagents-command-handler [args ctx api]
  (let [trimmed (trim args)
        cmd (string.lower (or (string.match trimmed "^(%S+)") ""))]
    (if (= cmd "show")
        (let [run-id (string.match trimmed "^%S+%s+(%S+)%s*$")
              run (and run-id (run-state.find run-id))]
          (api.emit {:type :assistant-text
                     :text (or (render-run-details run)
                               (if run-id
                                   (.. "No subagent run named " run-id)
                                   "Usage: /subagents show RUN_ID"))}))
        (= cmd "usage")
        (let [run-id (string.match trimmed "^%S+%s+(%S+)")]
          (api.emit {:type :assistant-text
                     :text (render-subagent-usage run-id)}))
        (= cmd "cancel")
        (let [run-id (string.match trimmed "^%S+%s+(%S+)%s*$")
              job (and run-id (run-state.job run-id))]
          (if job
              (do
                (job.handle:abort)
                (api.emit {:type :assistant-text
                           :text (.. "Requested cancellation for " run-id ".")}))
              run-id
              (api.emit {:type :assistant-text
                         :text (.. "No active background subagent run named " run-id)})
              (let [jobs (run-state.jobs)
                    n (run-state.active-count)]
                (if (= n 0)
                    (api.emit {:type :assistant-text
                               :text "No active subagent runs to cancel."})
                    (do
                      (each [_ bg (ipairs jobs)] (bg.handle:abort))
                      ;; Preserve blocking/current-turn cancellation behavior.
                      (when ctx (set ctx.cancel-requested? true))
                      (api.emit {:type :assistant-text
                                 :text (.. "Requested cancellation for " n
                                           " active subagent run(s).") }))))))
        (= cmd "steer")
        (let [(run-id note) (string.match trimmed "^%S+%s+(%S+)%s+(.+)$")]
          (if (or (not run-id) (= (trim note) ""))
              (api.emit {:type :assistant-text
                         :text "Usage: /subagents steer RUN_ID NOTE"})
              (let [run (run-state.request-steer! run-id note :user)]
                (if run
                    (api.emit {:type :assistant-text
                               :text (.. "Queued steering for " run-id ": "
                                         (fit note 120))})
                    (api.emit {:type :assistant-text
                               :text (.. "No active subagent run named " run-id)})))))
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
        (let [lines ["Available subagents (activate the `subagent` tool through `tool_search` first):"]
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

(fn parse-timeout-arg [raw]
  "Coerce an inline timeout argument to a positive number, or nil to use the
   default."
  (let [n (tonumber raw)]
    (if (and n (> n 0)) n nil)))

(fn effective-timeout [cfg args]
  "Use a per-call timeout as a shorter budget, never to exceed the agent or
   default policy ceiling."
  (let [ceiling (or cfg.timeout-seconds DEFAULT-TIMEOUT-SECONDS)
        requested (parse-timeout-arg args.timeout-seconds)]
    (if requested (math.min requested ceiling) ceiling)))

(fn with-call-timeout [cfg args]
  (let [out {}]
    (each [k v (pairs cfg)] (tset out k v))
    (set out.timeout-seconds (effective-timeout cfg args))
    out))

(fn inline-cfg [args]
  "Synthesize an agent config from inline call arguments so a subagent can run
   without a discovered agent .md file. The `prompt` becomes the child's system
   prompt; optional model/provider/timeout override routing as if declared in
   frontmatter."
  {:key "inline"
   :name "inline"
   :description ""
   :model (and (present? args.model) args.model)
   :provider (and (present? args.provider) args.provider)
   :timeout-seconds nil
   :body args.prompt})

(fn resolve-cfg [args]
  "Return (values cfg agent-label err) for either a named agent or an inline
   prompt. Named agents win when both are supplied."
  (let [{: agent : prompt} args]
    (if (present? agent)
        (let [(cfg err) (discover.find-agent agent)]
          (if err
              (values nil agent err)
              (not cfg)
              (values nil agent
                      {:unknown? true
                       :file agent
                       :reason (.. "unknown agent: " agent
                                   " (looked in project, user, and bundled agents)")})
              (values cfg agent nil)))
        (present? prompt)
        (values (inline-cfg args) "inline" nil)
        (values nil nil {:missing? true}))))

(fn background-supported? [ctx]
  "Return false for built-in presenters that cannot supply idle runtime ticks."
  (let [presenter (tostring (or (?. ctx :state :opts :presenter) ""))]
    (not (or (= presenter "stdio")
             (= presenter "print")
             (= presenter "json")))))

(fn private-run [id]
  (var found nil)
  (each [_ run (ipairs run-state._state.runs)]
    (when (and (not found) (= run.id id)) (set found run)))
  found)

(fn wait-for-run [run-id args ?yield-fn]
  (let [budget (or (parse-timeout-arg args.timeout-seconds) 30)
        deadline (+ (process.monotonic-ms) (* budget 1000))]
    (var run (run-state.find run-id))
    (while (and run (= run.status :running)
                (< (process.monotonic-ms) deadline))
      (pump-background-jobs!)
      (if ?yield-fn (?yield-fn) (process.sleep-ms 10))
      (set run (run-state.find run-id)))
    (if (not run)
        (result (.. "No subagent run named " run-id) true
                {:run-id run-id :found? false})
        (= run.status :running)
        (result (.. "Wait timed out; " run-id " is still running.") false
                {:run run :timed-out? true})
        (result (or (render-run-details run) "") false
                {:run run :timed-out? false}))))

(fn management-execute [args ctx ?yield-fn]
  (let [action (string.lower (tostring (or args.action "")))
        run-id (or args.run-id args.run_id)]
    (if (= action "list")
        (result (render-subagent-runs) false (run-state.snapshot))
        (= action "show")
        (if (not (present? run-id))
            (result "action 'show' requires 'run-id'" true)
            (let [run (run-state.find run-id)]
              (if run
                  (result (render-run-details run) false {:run run})
                  (result (.. "No subagent run named " run-id) true
                          {:run-id run-id :found? false}))))
        (= action "usage")
        (if (present? run-id)
            (let [run (run-state.find run-id)]
              (if run
                  (result (render-run-details run) false
                          {:run run :usage (run-usage-view run)})
                  (result (.. "No subagent run named " run-id) true
                          {:run-id run-id :found? false})))
            (let [runs (latest-runs)
                  views []]
              (each [_ r (ipairs runs)]
                (let [v (run-usage-view r)]
                  (table.insert views {:run-id r.id
                                       :agent r.agent
                                       :provider (and r.details r.details.provider)
                                       :model (and r.details r.details.model)
                                       :status r.status
                                       :usage (and v v.usage)
                                       :turns (and v v.turns)
                                       :provenance (and v v.provenance)
                                       :source (and v v.source)
                                       :complete? (and v v.complete?)})))
              (result (render-subagent-usage nil) false
                      {:runs views :active-count (run-state.active-count)})))
        (= action "wait")
        (if (not (present? run-id))
            (result "action 'wait' requires 'run-id'" true)
            (wait-for-run run-id args ?yield-fn))
        (= action "steer")
        (if (or (not (present? run-id)) (not (present? args.note)))
            (result "action 'steer' requires 'run-id' and 'note'" true)
            (let [current (run-state.find run-id)]
              (if (not current)
                  (result (.. "No active subagent run named " run-id) true)
                  (>= (or current.restart-count 0) MAX-STEERING-RESTARTS)
                  (result (.. "Cannot steer " run-id ": restart limit reached") true
                          {:run current :reason :restart-limit})
                  (let [run (run-state.request-steer! run-id args.note :agent)]
                    (result (.. "Queued steering for " run-id ".") false
                            {:run (run-state.find run.id)})))))
        (= action "cancel")
        (if (not (present? run-id))
            (result "action 'cancel' requires 'run-id'" true)
            (let [job (run-state.job run-id)]
              (if job
                  (do (abort-and-reap! [job] true)
                      (result (.. "Cancelled " run-id ".") false
                              {:run (run-state.find run-id)}))
                  (result (.. "No active background subagent run named " run-id) true))))
        (= action "cancel-all")
        (let [jobs (run-state.jobs)
              n (length jobs)]
          (when (> n 0) (abort-and-reap! jobs true))
          ;; A blocking subagent can only be cancelled through its owning turn.
          (when (and ctx (> (run-state.active-count) 0))
            (set ctx.cancel-requested? true))
          (result (if (> n 0)
                      (.. "Cancelled " n " background subagent run(s).")
                      "No active background subagent runs to cancel.") false
                  {:cancelled n :active-count (run-state.active-count)}))
        (= action "remove")
        (if (not (present? run-id))
            (result "action 'remove' requires 'run-id'" true)
            (let [(removed err) (run-state.remove! run-id)]
              (if removed
                  (result (.. "Removed " run-id ".") false {:run-id run-id})
                  (result (.. "Cannot remove " run-id ": " err) true
                          {:run-id run-id :reason err}))))
        (= action "retry")
        (if (not (present? run-id))
            (result "action 'retry' requires 'run-id'" true)
            (let [old (private-run run-id)]
              (if (not old)
                  (result (.. "No subagent run named " run-id) true)
                  (= old.status :running)
                  (result (.. run-id " is still running") true)
                  (not (and old.background? old.cfg old.task))
                  (result "retry is available only for retained background runs" true)
                  (>= (run-state.active-count) MAX-BACKGROUND-RUNS)
                  (result "cannot retry subagent: active run cap (4) reached" true)
                  (not (background-supported? ctx))
                  (result "background subagents require a ticking presenter (use the TUI)" true)
                  (let [r (launch-background old.cfg old.agent old.task
                                             old.requested-cwd old.cwd old.physical-cwd
                                             ctx (or old.collect :summary))]
                    (when r.details
                      (set r.details.retry-of run-id)
                      (let [retried (private-run r.details.run-id)]
                        (when retried (set retried.retry-of run-id))))
                    r))))
        (= action "clear")
        (if (> (run-state.active-count) 0)
            (result "cannot clear subagent history while runs are active; cancel them first" true)
            (let [n (length (run-state.runs))]
              (run-state.clear!)
              (result "Cleared subagent run history." false {:cleared n})))
        (= action "reset")
        (let [jobs (run-state.jobs)
              cancelled (length jobs)]
          (when (> cancelled 0) (abort-and-reap! jobs true))
          (if (> (run-state.active-count) 0)
              (do (when ctx (set ctx.cancel-requested? true))
                  (result "blocking subagent cancellation requested; reset again after it exits" true
                          {:cancelled cancelled
                           :active-count (run-state.active-count)}))
              (let [cleared (length (run-state.runs))]
                (run-state.clear!)
                (result "Cancelled active jobs and cleared subagent history." false
                        {:cancelled cancelled :cleared cleared}))))
        (result (.. "unknown subagent action: " action) true))))

(fn execute [args ctx ?yield-fn]
  (let [{: task : cwd} args]
    (if (present? args.action)
        (management-execute args ctx ?yield-fn)
        (not (present? task))
        (result "missing 'task'" true)
        (and (not (present? args.agent)) (not (present? args.prompt)))
        (result "missing 'agent' or 'prompt' (provide a named agent or an inline system prompt)" true)
        (let [requested-cwd (if (and cwd (not= cwd "")) cwd (path.cwd))
              launch-cwd (absolute-cwd requested-cwd)]
          (if (not (path.dir-exists? launch-cwd))
              (result (.. "cwd does not exist: " requested-cwd) true)
              (let [physical-cwd (path.pwd-physical launch-cwd)]
                (if (not physical-cwd)
                    (result (.. "cwd is not accessible: " requested-cwd) true)
                    (let [(cfg agent-label err) (resolve-cfg args)]
                      (if (and err err.unknown?)
                          (result err.reason true)
                          err
                          (invalid-agent-result agent-label err)
                          (and args.collect
                               (not (or (= args.collect :summary)
                                        (= args.collect :full)
                                        (= args.collect "summary")
                                        (= args.collect "full"))))
                          (result "collect must be 'summary' or 'full'" true)
                          (>= (run-state.active-count) MAX-BACKGROUND-RUNS)
                          (result "cannot launch subagent: active run cap (4) reached" true)
                          (and args.background (not (background-supported? ctx)))
                          (result "background subagents require a ticking presenter (use the TUI)" true)
                          args.background
                          (launch-background (with-call-timeout cfg args) agent-label task
                                             requested-cwd launch-cwd physical-cwd ctx
                                             (if (or (= args.collect :full)
                                                     (= args.collect "full"))
                                                 :full :summary))
                          (run-agent (with-call-timeout cfg args) agent-label task
                                     requested-cwd launch-cwd physical-cwd ctx
                                     ?yield-fn))))))))))

(fn M.register [api]
  ;; Handles contain Lua closures over process descriptors, so they cannot be
  ;; safely migrated across an extension reload. Reap active children before
  ;; registering the new behavior instead of retaining stale callbacks.
  (shutdown-background-jobs!)
  (run-state.reconcile-background!)
  (api.on :runtime-tick (fn [_ev]
                          (pump-background-jobs!)
                          (run-state.reconcile-background!)))
  (api.on :agent-shutdown (fn [_ev] (shutdown-background-jobs!)))
  (api.on :reset-conversation
          (fn [ev]
            ;; Only /new is a hard process boundary. Resume and handoff also
            ;; reset presenter content but must not silently destroy jobs.
            (when (= ev.reason :new)
              (shutdown-background-jobs! true)
              (run-state.reconcile-background!)
              (run-state.clear!))))
  (api.prompt agents-prompt-fragment
              {:order 62
               :id :available-subagents
               :title "Available subagents"
               :description "Discovered subagents that can be invoked after activating the subagent tool through tool_search."})
  (api.register :command
    {:name :agents
     :order 66
     :description "List discovered subagents and their model/timeout metadata"
     :complete agents-command-complete
     :handler (fn [args ctx] (agents-command-handler args ctx api))})
  (api.register :command
    {:name :subagents
     :order 67
     :description "Show active/recent subagent runs; use show, steer, or cancel with a run id"
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
     :exposure :search
     :parallel-safe? true
     :parallel-cap 4
     :snippet "Delegate and manage child fen agents with isolated context"
     :description (.. "Delegate a focused task to a child agent running in "
                      "a fresh fen process with its own context window. Provide "
                      "either a named `agent` (a discovered agent definition) "
                      "or an inline `prompt` (used directly as the child's "
                      "system prompt, so no agent file is required). By "
                      "default the child inherits the parent provider/model "
                      "when available; a named agent's frontmatter or the "
                      "inline `model`/`provider` args may override model, "
                      "provider, or both. A provider-only override passes only "
                      "that provider and intentionally omits the parent model. "
                      "Use this to keep long or self-contained work (research, "
                      "a scoped edit, a review pass) out of the main "
                      "conversation. Prefer narrow tasks and set "
                      "`timeout-seconds` to an explicit short budget when "
                      "partial progress would still be useful. The child normally returns final text; "
                      "failures and empty successful results return diagnostic "
                      "text with details, including provider/model sources. "
                      "Set `background: true` to launch explicitly without "
                      "blocking; completion is queued as a follow-up and the "
                      "full stored result is available through `/subagents show`. "
                      "Background jobs are read-only and never auto-start a turn. "
                      "Use action=list/show/usage/wait/steer/cancel/cancel-all/"
                      "remove/retry/clear/reset to inspect and manage stored "
                      "runs, including per-run and workflow token usage, "
                      "directly; management actions do "
                      "not launch a child. When several "
                      "subagent tool calls in the same assistant turn; fen may "
                      "run them concurrently, capped at 4. Named agents are "
                      "defined as markdown files under .fen/agents/ (project), "
                      "~/.config/fen/agents/ (user), or bundled with fen.")
     :parameters {:type :object
                  :properties {:action {:type :string
                                        :enum ["list" "show" "usage" "wait" "steer" "cancel" "cancel-all"
                                               "remove" "retry" "clear" "reset"]
                                        :description "Manage runs instead of launching: inspect, view token usage, wait, steer, cancel, retry, remove, clear inactive history, or reset all detached work."}
                               :run-id {:type :string
                                        :description "Run id used by show, wait, steer, cancel, remove, or retry actions."}
                               :note {:type :string
                                      :description "Steering note required by action=steer."}
                               :agent {:type :string
                                       :description "Name of a discovered agent to run (the .md filename without extension). Provide this or `prompt`."}
                               :prompt {:type :string
                                        :description "Inline system prompt for the child agent, used instead of a discovered agent file. Provide this or `agent`; `agent` wins if both are set."}
                               :task {:type :string
                                      :description "The task/prompt to hand to the child agent."}
                               :cwd {:type :string
                                     :description "Working directory for the child; validated to exist. Defaults to the current directory."}
                               :model {:type :string
                                       :description "Override the child model. Optional; defaults to the agent frontmatter or inherited parent model."}
                               :provider {:type :string
                                          :description "Override the child provider. Optional; a provider-only override omits the inherited model."}
                               :timeout-seconds {:type :number
                                                 :description "For launches, set a shorter positive child timeout capped by policy. For action=wait, set the polling budget (default 30 seconds)."}
                               :background {:type :boolean
                                            :description "Run detached and return immediately with a run id. Defaults to false."}
                               :collect {:type :string
                                         :enum ["summary" "full"]
                                         :description "For background completion follow-ups, queue a compact summary (default) or the full final result."}}}
     :execute execute})
  true)

M
