;; subagent tool — delegate a focused task to a live child fen process.
;;
;; Out-of-process by design (see issue #16): the child is a fresh `fen` with its
;; own context window, an agent-specific system prompt, and explicit model/
;; provider routing. By default it inherits the parent agent's provider/model
;; when the tool context exposes them; agent frontmatter can override either,
;; with provider-only intentionally omitting the inherited model.
;;
;; Each run spawns one `fen --presenter rpc` child and drives it over the wire
;; protocol (docs/wire.md, #516): the task is the first `prompt`, steering is
;; `steer`, budgets send `finalize`, cancellation sends `cancel`, and a child
;; back in `ready` is sent `close`. Blocking and background runs share one
;; driver (`pump!`); blocking just pumps its run to completion while yielding.

(local types (require :fen.core.types))
(local process (require :fen.util.process))
(local clock (require :fen.util.clock))
(local runtime (require :fen.runtime))
(local path (require :fen.util.path))
(local json (require :fen.util.json))
(local text (require :fen.util.text))
(local turn-result (require :fen.util.turn_result))
(local discover (require :fen.extensions.subagent.discover))
(local channel (require :fen.extensions.subagent.channel))
(local wire (require :fen.util.wire))
(local wire-session (require :fen.util.wire_session))
(local worktrees (require :fen.extensions.subagent.worktrees))
(local runs (require :fen.extensions.subagent.runs))
(local usage-util (require :fen.util.usage))
(local presenter-registry (require :fen.core.extensions.register.presenter))

(local M {})

(local DEFAULT-TIMEOUT-SECONDS 2700)
(local MAX-PROMPT-AGENTS 8)
(local MAX-PROMPT-DESCRIPTION-BYTES 96)
(local MAX-BACKGROUND-RUNS 4)
(local PARTIAL-EVENT-TAIL 6)
;; Latest assistant text kept for a run that ends without `result`.
(local PARTIAL-TEXT-BYTES (* 16 1024))
(local TICK-MS 30)
;; Event batches read per pump; a final drain reads everything.
(local POLL-BATCHES 4)
;; `cancel`, `finalize`, and the child's deadline land only at its next
;; cooperative yield, so the parent keeps a kill backstop: after `cancel` or
;; `exit`, the process gets this long before its group is killed. Keep it
;; generous: a kill does not reach tool subprocesses in their own sessions.
(local CANCEL-GRACE-MS 3000)
;; A `finalize` with no `exit` by then is cancelled.
(local FINALIZE-GRACE-MS 120000)
;; The process timeout trails the child's own deadline by this much.
(local DEADLINE-GRACE-SECONDS 5)
;; Synchronous reaps pump at most this many ticks past the cancel grace.
(local REAP-TICKS (math.floor (/ (+ CANCEL-GRACE-MS 2000) TICK-MS)))
(local FINALIZATION-NOTE "Investigation budget reached. Return your final answer or review artifact now. Do not run more discovery tools. Lead with findings or say no findings; label uncertainty explicitly.")

(fn copy-usage-table [t]
  (let [out {}]
    (when (= (type t) :table) (each [k v (pairs t)] (tset out k v)))
    out))

(fn sanitize-run! [run]
  "Defensively deep-copy a run copy's nested tables in place so structured
   callers (introspection, management results) cannot mutate live run state.
   Several callers ignore the return value and rely on RUN itself being
   sanitized. Idempotent, since copy-run of an already-copied run is stable."
  (when (= (type run) :table)
    (let [copy (runs.copy-run run)]
      (each [k v (pairs copy)] (tset run k v))))
  run)

(local ARTIFACT_TOOL_NAMES {:edit true :write true})

(fn artifact-tool? [name]
  (let [key (tostring (or name ""))]
    (or (= true (. ARTIFACT_TOOL_NAMES key))
        (= true (. ARTIFACT_TOOL_NAMES (string.lower key))))))

(fn contains? [s needle]
  (and (= (type s) :string) (string.find s needle 1 true)))

(fn event-contains-diff? [ev]
  (or (contains? ev.summary "diff --git")
      (contains? ev.error "diff --git")
      (let [(ok? encoded) (pcall json.encode (or ev.result ev))]
        (and ok? (contains? encoded "diff --git")))))

(fn artifact-event? [ev]
  (or (and (= ev.type :assistant-text) ev.final?)
      (and (= ev.type :tool-call) (artifact-tool? ev.name))
      (and (= ev.type :tool-result)
           (not ev.is-error?)
           (or (artifact-tool? ev.name)
               (and (= (tostring (or ev.name "")) "bash")
                    (event-contains-diff? ev))))))

(fn artifact-kind [ev]
  (if (= ev.type :assistant-text)
      :assistant-final
      (= ev.type :tool-call)
      :mutating-tool-call
      (= ev.type :tool-result)
      (if ev.is-error? :failing-tool-result :tool-result)
      ev.type))

(fn artifact-summary [ev]
  (let [s (or ev.summary ev.error ev.name "")]
    (if (= (tostring s) "") nil s)))

(fn maybe-record-artifact! [run ev]
  (when (and (= ev.type :assistant-text) ev.final?)
    (set run.final-answer-produced? true))
  (let [summary (artifact-summary ev)]
    (when (and (artifact-event? ev) summary)
      (runs.mark-first-artifact!
        run.id {:kind (artifact-kind ev)
                :summary summary
                :elapsed-ms (- (clock.monotonic-ms)
                               (or run.started-at-ms (clock.monotonic-ms)))
                :event-count (or run.event-count 0)}))))

(fn maybe-record-final-text-artifact! [run child-text ?duration-ms]
  (let [summary (text.trim (text.first-line (or child-text "")))]
    (when (not= summary "")
      (set run.final-answer-produced? true)
      (runs.mark-first-artifact!
        run.id {:kind :assistant-final
                :summary (text.truncate-line summary 160)
                :elapsed-ms (or ?duration-ms
                                (- (clock.monotonic-ms)
                                   (or run.started-at-ms (clock.monotonic-ms))))
                :event-count (or run.event-count 0)}))))

(fn lower [v]
  (string.lower (tostring (or v ""))))

(fn compact-event-line [v ?limit]
  (text.truncate-line (text.first-line (tostring (or v "")))
                      (or ?limit 160)))

(fn paths-summary [args]
  (or (and args args.path (tostring args.path))
      (and args args.file (tostring args.file))
      (and args (= (type args.paths) :table)
           (let [parts []]
             (each [_ p (ipairs args.paths)]
               (table.insert parts
                             (if (= (type p) :table)
                                 (tostring (or p.path p.file p))
                                 (tostring p))))
             (when (> (length parts) 0)
               (table.concat parts ","))))))

(fn inspection-fingerprint [ev]
  (let [name (lower ev.name)
        args (or ev.arguments {})]
    (if (= name "read")
        (let [p (paths-summary args)]
          (and p (.. "read:" p)))
        (= name "grep")
        (.. "grep:" (tostring (or args.path ".")) ":"
            (tostring (or args.glob "")) ":"
            (compact-event-line (or args.pattern ev.summary) 96))
        (= name "find")
        (.. "find:" (tostring (or args.path ".")) ":"
            (compact-event-line (or args.pattern ev.summary) 96))
        (= name "ls")
        (.. "ls:" (tostring (or args.path ".")))
        (= name "bash")
        (let [cmd (compact-event-line (or args.cmd ev.summary) 160)]
          (and (not= cmd "") (.. "bash:" cmd)))
        nil)))

(fn trim-run-list! [xs max]
  (while (> (length xs) max)
    (table.remove xs 1)))

(fn record-inspection-warning! [run ev]
  (let [fp (inspection-fingerprint ev)]
    (when fp
      (let [count (+ (or (. run.inspection-fingerprints fp) 0) 1)]
        (tset run.inspection-fingerprints fp count)
        (when (>= count 3)
          (let [summary (.. "repeated inspection: " fp " (" count " times)")
                existing (accumulate [found nil _ w (ipairs run.repeated-inspection-warnings)
                                      &until found]
                           (when (= w.fingerprint fp) w))]
            (if existing
                (do
                  (set existing.count count)
                  (set existing.summary summary))
                (do
                  (table.insert run.repeated-inspection-warnings
                                {:tool ev.name
                                 :fingerprint fp
                                 :count count
                                 :summary summary})
                  (trim-run-list! run.repeated-inspection-warnings 20)))))))))

(fn stamp-artifact-details! [run details]
  (when (and run details)
    (set details.time-to-first-artifact-ms run.time-to-first-artifact-ms)
    (when run.first-artifact-kind
      (set details.first-artifact-kind run.first-artifact-kind))
    (when run.first-artifact-summary
      (set details.first-artifact-summary run.first-artifact-summary))
    (when run.artifact-checkpoint-seconds
      (set details.artifact-checkpoint-seconds run.artifact-checkpoint-seconds)))
  details)

(fn apply-usage-telemetry! [run details]
  "Stamp usage onto DETAILS: the child's `result` usage sums its whole run and
   is authoritative; without a result, fall back to the completed-turn usage
   folded from :llm-end events, marked incomplete."
  (let [acc run.usage-acc
        raw details.usage
        blob (usage-util.canonical-usage raw)]
    (if blob
        (do
          (set details.usage blob)
          (set details.usage-provenance (usage-util.usage-provenance raw :provider-reported))
          (set details.usage-source :final-result)
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
    (stamp-artifact-details! run details)
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

(fn present? [v]
  (and v (not= v "")))

(fn blank? [s]
  (or (not s) (= s "")))

(fn effective-routing [cfg ctx]
  "Resolve the child process provider/model policy.

   With no frontmatter override, inherit the parent provider/model when the
   tool context exposes ctx.agent. A model-only override keeps the inherited
   provider and replaces the model. A provider+model override uses both
   frontmatter values. A provider-only override deliberately omits the inherited
   model rather than pairing it with a different provider."
  (let [agent (and ctx ctx.agent)
        inherited-provider (and agent agent.provider-name)
        inherited-model (and agent agent.model)
        fm-provider (and (present? cfg.provider) cfg.provider)
        fm-model (and (present? cfg.model) cfg.model)
        provider-override? (present? fm-provider)]
    {:provider (or fm-provider inherited-provider)
     :model (if fm-model fm-model
                provider-override? nil
                inherited-model)
     :provider-source (if fm-provider :frontmatter
                          inherited-provider :inherited
                          :unset)
     :model-source (if fm-model :frontmatter
                       provider-override? :omitted-provider-override
                       inherited-model :inherited
                       :unset)}))

(fn tool-name-in-list? [names wanted]
  (accumulate [found? false _ name (ipairs (or names [])) &until found?]
    (= (tostring name) (tostring wanted))))

(fn filter-tool-names [names allowed]
  (icollect [_ name (ipairs (or names []))]
    (when (tool-name-in-list? allowed name) (tostring name))))

(fn restricted-name-list [restriction]
  "Return parent-denied names in deterministic order.

   `restricted-names` is intentionally a set: #414 fixed it to describe the
   declared-minus-active tools. The child argv needs a stable list, so sort the
   set only at this process boundary."
  (let [names []]
    (each [name restricted? (pairs (or restriction.restricted-names {}))]
      (when restricted?
        (table.insert names (tostring name))))
    (table.sort names (fn [a b] (< a b)))
    names))

(fn empty-tool-intersection-error [restriction child-tools]
  (if (= restriction.flag "--tools")
      {:kind :subagent-tool-restriction
       :reason :empty-intersection
       :parent-flag restriction.flag
       :parent-tools restriction.active-names
       :child-tools child-tools
       :message "cannot launch subagent: parent --tools and child --tools have no tools in common"}
      {:kind :subagent-tool-restriction
       :reason :empty-intersection
       :parent-flag restriction.flag
       :parent-denied-tools (restricted-name-list restriction)
       :child-tools child-tools
       :message "cannot launch subagent: parent --denied-tools removes every tool from the child's --tools allowlist"}))

(fn child-tool-policy [cfg restriction]
  "Resolve the child argv policy without allowing it to widen the parent.

   A parent's allowlist intersects a child allowlist. A parent's denylist is
   forwarded when the child has no allowlist, otherwise denied names are
   removed from the child's allowlist because the CLI flags conflict."
  (if (not restriction)
      (values {:flag (when cfg.tools "--tools") :tools cfg.tools} nil)
      (= restriction.flag "--no-tools")
      (values {:flag "--no-tools"} nil)
      (= restriction.flag "--tools")
      (let [effective (if cfg.tools
                          (filter-tool-names cfg.tools restriction.active-names)
                          restriction.active-names)]
        (if (= (length effective) 0)
            (values nil (empty-tool-intersection-error restriction cfg.tools))
            (values {:flag "--tools" :tools effective} nil)))
      (= restriction.flag "--denied-tools")
      (let [denied (restricted-name-list restriction)
            effective (and cfg.tools
                           (icollect [_ name (ipairs cfg.tools)]
                             (when (not (tool-name-in-list? denied name))
                               (tostring name))))]
        (if (and cfg.tools (= (length effective) 0))
            (values nil (empty-tool-intersection-error restriction cfg.tools))
            cfg.tools
            (values {:flag "--tools" :tools effective} nil)
            (values {:flag "--denied-tools" :tools denied} nil)))
      (values nil {:kind :subagent-tool-restriction
                   :reason :invalid-parent-restriction
                   :parent-flag restriction.flag
                   :message (.. "cannot launch subagent: unsupported parent tool restriction "
                                (tostring restriction.flag))})))

(fn normalized-task [task]
  ;; Deliberately preserve case and punctuation: under-warning is safer than
  ;; claiming two meaningfully different child requests are identical.
  (string.gsub (text.trim (tostring (or task ""))) "%s+" " "))

(fn task-fingerprint [agent task cwd routing]
  "A lightweight stable key for retained-history timeout telemetry."
  (table.concat [(tostring (or agent ""))
                 (normalized-task task)
                 (tostring (or cwd ""))
                 (tostring (or routing.provider ""))
                 (tostring (or routing.model ""))]
                "\31"))

(fn repeated-timeout-warning-text [warning]
  (.. "Attempt " (tostring warning.count)
      " after " (tostring warning.prior-count)
      " retained identical timeouts without an artifact/mutation. "
      warning.suggestion
      (if warning.history-truncated?
          " Retained history is truncated, so this is a lower bound."
          "")))

(fn child-argv [bin sys-path routing child-policy]
  "argv for one live child: the task arrives as the first wire `prompt`.
   Children stay --no-session: fen has no session-location override, and a
   child session in the user's store would clutter /resume and race
   --continue."
  (let [argv [bin "--presenter" "rpc" "--system-file" sys-path "--no-session"]]
    (each [_ [flag val] (ipairs [["--model" routing.model]
                                 ["--provider" routing.provider]])]
      (when val
        (table.insert argv flag)
        (table.insert argv val)))
    (when child-policy.flag
      (table.insert argv child-policy.flag)
      (when child-policy.tools
        (table.insert argv (table.concat child-policy.tools ","))))
    argv))

(fn absolute-cwd [cwd]
  "Return an absolute spelling for CWD while preserving a symlink final component."
  (if (= (string.sub cwd 1 1) "/")
      cwd
      (path.realpath cwd)))

(fn task-with-cwd-context [run]
  (.. "Subagent launch context:\n"
      "- Requested cwd: " run.requested-cwd "\n"
      "- Child PWD: " run.cwd "\n"
      "- Physical cwd: " run.physical-cwd "\n\n"
      "Treat Child PWD as the authoritative working directory for all "
      "relative paths and tool calls. If the task concerns a git worktree "
      "or diff, verify `pwd` and `git status --short` in that directory "
      "before drawing conclusions.\n\n"
      "Task:\n"
      run.task
      (if run.background?
          "\n\nBackground authority:\nThis detached job is read-only. Do not edit files or mutate repositories. Return findings to the parent agent, which owns any edits.\n"
          "")))

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

(local DETAIL-LINES
  [["run id" :run-id] ["agent" :agent] ["requested cwd" :requested-cwd]
   ["cwd" :cwd] ["physical cwd" :physical-cwd] ["provider" :provider]
   ["provider source" :provider-source] ["model" :model]
   ["model source" :model-source] ["exit code" :exit-code] ["signal" :signal]
   ["timed out" :timed-out?] ["child exit" :child-exit]
   ["child error" :child-error] ["error" :error] ["stop reason" :stop-reason]
   ["result truncated" :result-truncated?] ["duration ms" :duration-ms]
   ["timeout seconds" :timeout-seconds] ["event count" :event-count]
   ["event errors" :event-error-count] ["steering notes" :steering-count]
   ["turn count" :turn-count] ["tool call count" :tool-call-count]
   ["max turns" :max-turns] ["max tool calls" :max-tool-calls]
   ["budget finalization requested" :budget-finalization-requested?]
   ["budget finalization reason" :budget-finalization-reason]
   ["repeated inspection warnings" :repeated-inspection-warning-count]])

(fn diagnostic-text [summary details ?child-text]
  (let [lines [summary]]
    (each [_ [label key] (ipairs DETAIL-LINES)]
      (add-detail-line lines label (. details key)))
    (when details.repeated-timeout-warning
      (table.insert lines (.. "\nRepeated timeout warning: "
                              (repeated-timeout-warning-text
                                details.repeated-timeout-warning))))
    (add-detail-line lines "usage" (summarize-usage details.usage))
    (add-detail-line lines "time to first artifact ms" details.time-to-first-artifact-ms)
    (add-detail-line lines "first artifact" details.first-artifact-kind)
    (add-detail-line lines "first artifact summary" details.first-artifact-summary)
    (add-detail-line lines "output truncated" details.output-truncated?)
    (add-detail-line lines "full output" details.full-output-path)
    (add-detail-line lines "partial progress" details.partial-progress?)
    (add-detail-line lines "partial assistant text" details.partial-assistant-text?)
    (when (not (blank? details.inspection-warning-tail))
      (table.insert lines (.. "\nInspection warnings:\n" details.inspection-warning-tail)))
    (when (not (blank? details.event-tail))
      (table.insert lines (.. "\nLatest child progress:\n" details.event-tail)))
    (when (and details.timed-out? details.partial-progress?)
      (table.insert lines "\nNext action: continue from the progress above, or retry with a narrower task and an explicit timeout-seconds budget."))
    (when (not (blank? ?child-text))
      (table.insert lines (.. "\nChild message:\n" ?child-text)))
    (when (not (blank? details.output-tail))
      (table.insert lines (.. "\nChild output tail:\n" details.output-tail)))
    (table.concat lines "\n")))

(fn append-local-event! [run ev]
  "Record a parent-side lifecycle event in the run's retained stream. Local
   events are not child artifacts, so they never count toward
   time-to-first-artifact."
  (let [normalized (wire.normalize ev {:run-id run.id
                                       :agent run.agent
                                       :requested-cwd run.requested-cwd
                                       :cwd run.cwd
                                       :physical-cwd run.physical-cwd})]
    (when (= (type ev.summary) :string)
      (set normalized.summary (compact-event-line ev.summary)))
    (runs.append-event! run.id normalized)
    normalized))

(fn progress-label [ev]
  (let [typ (tostring (or ev.type :event))
        name (and ev.name (.. " " (tostring ev.name)))
        summary (or ev.summary ev.error "")]
    (.. "- " typ (or name "")
        (if (blank? summary) "" (.. ": " summary)))))

(local LIFECYCLE-EVENT-TYPES {:subagent-start true :subagent-done true
                              :agent-started true :llm-start true :llm-end true})

(fn partial-event-details [run]
  (let [events (or run.events [])
        tail []]
    (for [i (math.max 1 (+ 1 (- (length events) PARTIAL-EVENT-TAIL))) (length events)]
      (let [ev (. events i)]
        (when (not (. LIFECYCLE-EVENT-TYPES ev.type))
          (table.insert tail (progress-label ev)))))
    {:partial-progress? (> (length tail) 0)
     :partial-assistant-text? (not (not run.partial-assistant-text?))
     :event-tail (and (> (length tail) 0) (table.concat tail "\n"))}))

(fn inspection-warning-tail [run]
  (let [warnings (or run.repeated-inspection-warnings [])
        lines []]
    (for [i (math.max 1 (+ 1 (- (length warnings) PARTIAL-EVENT-TAIL))) (length warnings)]
      (let [w (. warnings i)]
        (table.insert lines (.. "- " (tostring (or w.summary w.fingerprint "warning"))))))
    (and (> (length lines) 0) (table.concat lines "\n"))))

(fn event-details [run]
  (let [details {:budget-limited? (not (not run.budget-limited?))
                 :event-count (or run.event-count 0)
                 :event-error-count (length (or run.event-errors []))
                 :steering-count (length (or run.steering-notes []))
                 :turn-count (or run.turn-count 0)
                 :tool-call-count (or run.tool-call-count 0)
                 :max-turns run.max-turns
                 :max-tool-calls run.max-tool-calls
                 :budget-finalization-requested? run.budget-finalization-requested?
                 :budget-finalization-reason run.budget-finalization-reason
                 :final-answer-produced? run.final-answer-produced?
                 :repeated-inspection-warning-count (length (or run.repeated-inspection-warnings []))
                 :repeated-inspection-warnings run.repeated-inspection-warnings
                 :repeated-timeout-warning run.repeated-timeout-warning
                 :inspection-warning-tail (inspection-warning-tail run)}]
    (each [k v (pairs (partial-event-details run))]
      (tset details k v))
    details))

(fn checkpoint-exceeded? [run]
  "True when a no-progress artifact checkpoint has elapsed with no artifact yet.
   Uses the same os.time clock as runs.copy-run's display flag so enforcement
   and reporting agree."
  (and run.artifact-checkpoint-seconds
       (not run.first-artifact)
       (>= (os.difftime (os.time) (or run.started-at (os.time)))
           run.artifact-checkpoint-seconds)))

(fn budget-reason [run]
  ;; max-turns trips only once the child continues past its Nth turn: an
  ;; answer on exactly turn N must not be interrupted.
  (if run.job.past-max-turns?
      (.. "max-turns " (tostring run.max-turns) " reached")
      (and run.max-tool-calls
           (>= (or run.tool-call-count 0) run.max-tool-calls))
      (.. "max-tool-calls " (tostring run.max-tool-calls) " reached")
      (checkpoint-exceeded? run)
      (.. "no artifact within checkpoint "
          (tostring run.artifact-checkpoint-seconds) "s")
      nil))

;; ----------------------------------------------------------------
;; The live-child driver
;; ----------------------------------------------------------------

(fn observe-child-event! [run ev]
  "Record one forwarded display event: retained tail, budget counters,
   inspection warnings, usage, the latest assistant text, and artifacts."
  (runs.append-event! run.id ev)
  (when (and run.max-turns
             (or (= ev.type :tool-call) (= ev.type :llm-start))
             (>= (or run.turn-count 0) run.max-turns))
    (set run.job.past-max-turns? true))
  (if (= ev.type :tool-call)
      (do (set run.tool-call-count (+ (or run.tool-call-count 0) 1))
          (record-inspection-warning! run ev))
      (= ev.type :llm-end)
      (do (set run.turn-count (+ (or run.turn-count 0) 1))
          ;; Completed-turn usage survives runs that end without `result`.
          (when ev.usage (runs.accumulate-usage! run.id ev.usage)))
      (= ev.type :llm-start)
      (set run.job.delta-text nil)
      (and (= ev.type :assistant-text) (present? ev.text))
      (set run.job.partial-text ev.text)
      ;; Streamed replies arrive as deltas; keep the latest reply's text.
      (= ev.type :assistant-text-delta)
      (set run.job.delta-text (text.utf8-prefix (.. (or run.job.delta-text "") (or ev.delta ""))
                                                PARTIAL-TEXT-BYTES))
      (= ev.type :assistant-stream-end)
      (when (present? run.job.delta-text)
        (set run.job.partial-text run.job.delta-text)
        (set run.job.delta-text nil)))
  (maybe-record-artifact! run
                          ;; A streamed final answer ends with this event.
                          (if (and (= ev.type :assistant-stream-end) ev.final?
                                   (present? run.job.partial-text))
                              {:type :assistant-text :final? true
                               :summary (compact-event-line run.job.partial-text)}
                              ev)))

(fn handle-message! [run msg]
  (let [typ msg.type]
    (if (= typ :control-ack)
        (when (= msg.status :rejected)
          (let [control (or msg.control {})
                steer? (= control.type :steer)]
            (append-local-event! run {:type (if steer? :steering-rejected :warning)
                                      :summary (.. (tostring (or control.type "control"))
                                                   " rejected: "
                                                   (tostring (or msg.reason "")))})))
        (not (wire-session.lifecycle-event? typ))
        (let [ev {}]
          ;; Keep the canonical display event; drop the wire envelope.
          (each [k v (pairs msg)]
            (when (not (or (= k :v) (= k :seq) (= k :run)))
              (tset ev k v)))
          (observe-child-event! run ev)))))

(fn drain-channel! [run ?batches]
  "Read up to ?BATCHES bounded event batches, or until the file is drained."
  (let [ch run.job.channel]
    (var n 0)
    (var more? true)
    (while (and more? (or (not ?batches) (< n ?batches)) (< n 10000))
      (set n (+ n 1))
      (let [(msgs errors) (channel.poll ch)]
        (each [_ msg (ipairs msgs)] (handle-message! run msg))
        (each [_ err (ipairs errors)] (runs.append-event-error! run.id err))
        (set more? (> (+ (length msgs) (length errors)) 0))))))

(fn send-control! [run typ ?payload]
  (let [(seq err) (channel.send! run.job.channel typ ?payload)]
    (when (not seq)
      (append-local-event! run {:type :warning
                                :summary (.. "cannot send " (tostring typ) ": "
                                             (tostring err))}))
    seq))

(fn arm-kill! [job ms]
  (when (not job.kill-at-ms)
    (set job.kill-at-ms (+ (clock.monotonic-ms) ms))))

(fn send-cancel! [run]
  "Send `cancel` once, then kill the process group if it outlives the grace."
  (let [job run.job]
    (when (not job.cancel-sent?)
      (set job.cancel-sent? true)
      (send-control! run :cancel)
      (arm-kill! job CANCEL-GRACE-MS))))

(fn maybe-finalize! [run]
  "Send `finalize` once when an investigation budget is reached before a final
   answer; the child answers from its own conversation with tools disabled."
  (let [reason (budget-reason run)
        status run.job.channel.status]
    (when (and reason
               (not run.final-answer-produced?)
               (not run.budget-finalization-requested?)
               ;; In `ready` the task turn is done and `close` returns it.
               (= status :running))
      (set run.budget-finalization-requested? true)
      (set run.budget-finalization-reason reason)
      (set run.budget-limited? true)
      (append-local-event! run {:type :budget-finalization :summary reason})
      (send-control! run :finalize {:note (.. FINALIZATION-NOTE "\nReason: " reason)})
      (set run.job.finalize-by-ms (+ (clock.monotonic-ms) FINALIZE-GRACE-MS)))))

(fn drive! [run]
  "Map the run's requests onto controls for the child's mirrored state."
  (let [job run.job
        ch job.channel]
    (if (or ch.exit ch.error job.cancel-requested?)
        (if ch.exit
            (arm-kill! job CANCEL-GRACE-MS)
            (send-cancel! run))
        (do
          (var note (runs.take-steering! run.id))
          (while note
            (send-control! run :steer {:text note.note})
            (set note (runs.take-steering! run.id)))
          (maybe-finalize! run)
          (if (and job.finalize-by-ms (>= (clock.monotonic-ms) job.finalize-by-ms))
              (send-cancel! run)
              (and (not job.close-sent?) (channel.idle? ch))
              ;; Back in `ready` with nothing outstanding: the task turn is
              ;; done, so ask for `result` and `exit`.
              (do (set job.close-sent? true)
                  (send-control! run :close)))))
    (when (and job.kill-at-ms (>= (clock.monotonic-ms) job.kill-at-ms))
      (job.handle:abort))))

(fn result-failed? [res]
  "A `result` whose last assistant ended in error, tool use, or an abort (or
   that has none) is a failed run, as for any headless turn."
  (let [reason (?. res :stop-reason)]
    (or (not res)
        (turn-result.failed? true (if (or (not reason) (= reason "none"))
                                      []
                                      [{:role :assistant :stop-reason reason}])))))

(fn outcome-status [ch r ?err]
  "Run status from the child's `exit` event, else from the process exit."
  (let [exit-status (?. ch :exit :status)]
    (if ?err :failed
        (= exit-status :done) (if (result-failed? ch.result) :failed :completed)
        exit-status exit-status
        ;; A protocol failure (e.g. a version mismatch) is a failure even
        ;; though the parent then cancels and kills the child.
        (?. ch :error) :failed
        (?. r :timed-out?) :timed-out
        (?. r :cancelled?) :cancelled
        :failed)))

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

(fn finish! [run process-result ?err]
  "Settle a run once its child process is gone (or never started)."
  (let [job run.job
        ch job.channel
        r (or process-result {})]
    (when ch
      (drain-channel! run)
      (channel.close! ch))
    (let [status (outcome-status ch r ?err)
          res (or (?. ch :result) {})
          failure? (not= status :completed)
          ;; Without `result`, answer with the latest (possibly in-flight) reply.
          child-text (if failure?
                         (or (text.blank->nil job.delta-text) job.partial-text "")
                         (or res.final-text ""))
          empty-final? (and (not failure?) (blank? res.final-text))
          routing job.routing
          details {:run-id run.id
                   :agent run.agent
                   :requested-cwd run.requested-cwd
                   :cwd run.cwd
                   :physical-cwd run.physical-cwd
                   :provider routing.provider
                   :model routing.model
                   :provider-source routing.provider-source
                   :model-source routing.model-source
                   :usage res.usage
                   :stop-reason res.stop-reason
                   :result-truncated? res.truncated?
                   :duration-ms (or r.duration-ms
                                    (- (clock.monotonic-ms) run.started-at-ms))
                   :timeout-seconds run.timeout-seconds
                   :timed-out? (= status :timed-out)
                   :exit-code r.exit-code
                   :signal r.signal
                   :child-exit (?. ch :exit :status)
                   :child-error (or (?. ch :exit :error) (?. ch :error))
                   :error (and ?err (text.first-line (tostring ?err)))
                   :output-tail r.output
                   :output-truncated? r.truncated?
                   :full-output-path (when (not run.background?) r.full-output-path)
                   :result child-text}]
      (when (not failure?)
        (maybe-record-final-text-artifact! run res.final-text r.duration-ms))
      (each [k v (pairs (event-details run))]
        (tset details k v))
      (let [diagnostic (if failure?
                           (diagnostic-text (if ?err
                                                "Subagent failed before producing a result."
                                                "Subagent failed.")
                                            details child-text)
                           empty-final?
                           (diagnostic-text "Subagent completed with empty final text."
                                            details nil)
                           child-text)]
        (append-local-event! run {:type :subagent-done :status status
                                  :summary child-text})
        (apply-usage-telemetry! run details)
        (runs.finish! run.id status details)
        (each [_ p (pairs [job.sys-path (?. ch :control-path) (?. ch :event-path)])]
          (os.remove p))
        ;; Background inspection uses the result and bounded output tail; the
        ;; raw process spill has no consumer there.
        (when (and run.background? r.full-output-path)
          (os.remove r.full-output-path))
        (set job.finished? true)
        (set job.outcome (result diagnostic failure? details))
        (when (and run.background? (not job.quiet?))
          (queue-background-completion! run status child-text diagnostic))))))

(fn pump! [run]
  "One cooperative driver pass for a live child: read its events, send any
   steer/finalize/close/cancel the run needs, enforce the kill backstop, and
   settle the run when the process exits. Blocking and background runs share
   it. Returns true once the run has settled."
  (let [job run.job]
    (when (not job.finished?)
      (drain-channel! run POLL-BATCHES)
      (drive! run)
      (let [(ok? done? r) (pcall job.handle.resume job.handle)]
        (if (not ok?) (finish! run nil done?)
            done? (finish! run r nil))))
    job.finished?))

(fn reap! [runs-to-reap]
  "Cancel RUNS-TO-REAP and settle them synchronously: `cancel`, then a kill
   after the grace window, bounded in case a handle never reports exit."
  (each [_ run (ipairs runs-to-reap)]
    (set run.job.cancel-requested? true)
    (pump! run))
  (each [_ run (ipairs runs-to-reap)]
    (var ticks 0)
    (while (and (not (pump! run)) (< ticks REAP-TICKS))
      (set ticks (+ ticks 1))
      (clock.sleep-ms TICK-MS))
    (when (not run.job.finished?)
      (run.job.handle:abort)
      (finish! run {:cancelled? true} "child did not exit after cancellation"))))

(fn pump-background-jobs! []
  (each [_ run (ipairs (runs.jobs))]
    (pump! run)))

(fn shutdown-background-jobs! [?quiet]
  (let [jobs (runs.jobs)]
    (each [_ run (ipairs jobs)]
      (set run.job.quiet? ?quiet))
    (reap! jobs)))

(fn active-record [id]
  (let [run (runs.record id)]
    (when (and run (= run.status :running) run.job (not run.job.finished?))
      run)))

(fn request-cancel! [run]
  "Ask a run's driver to cancel its child: `cancel`, then a kill after grace."
  (when run.job
    (set run.job.cancel-requested? true)))

(fn start-child! [run bin sys-path routing child-policy]
  "Create the private control and event files, queue the task as the first
   `prompt`, and spawn the child once."
  (set run.job {:sys-path sys-path :routing routing})
  (let [control-path (os.tmpname)
        event-path (os.tmpname)
        ch (channel.open run.id control-path event-path)]
    (set run.job.channel ch)
    (send-control! run :prompt {:text (task-with-cwd-context run)})
    (set run.job.handle
         (process.start-captured
           {:argv (child-argv bin sys-path routing child-policy)
            :cwd run.cwd
            :env {:FEN_WIRE_CONTROL_PATH control-path
                  :FEN_WIRE_EVENT_PATH event-path
                  :FEN_WIRE_RUN_ID run.id
                  :FEN_WIRE_DEADLINE (tostring (+ (os.time)
                                                  (math.ceil run.timeout-seconds)))
                  :PWD run.cwd}
            :timeout-seconds (+ run.timeout-seconds DEADLINE-GRACE-SECONDS)
            :spill? true}))))

(fn launch! [cfg agent task requested-cwd cwd physical-cwd ctx ?opts]
  "Validate policy, record the run, and spawn its child. Returns the run, or
   nil plus an error tool result."
  (let [opts (or ?opts {})
        (child-policy policy-error)
        (child-tool-policy cfg (?. ctx :agent :tool-restriction))
        bin (runtime.binary-path)
        sys-path (and (not policy-error) bin (write-temp cfg.body))]
    (if policy-error (values nil (result policy-error.message true policy-error))
        (not bin) (values nil (result "cannot resolve fen binary to spawn subagent" true))
        (not sys-path) (values nil (result "cannot stage subagent system prompt" true))
        (let [routing (effective-routing cfg ctx)
              fingerprint (task-fingerprint agent task cwd routing)
              run (runs.start! {:agent agent :task task :cfg cfg
                                :task-fingerprint fingerprint
                                :repeated-timeout-warning (runs.repeated-timeout-warning fingerprint)
                                :requested-cwd requested-cwd
                                :cwd cwd :physical-cwd physical-cwd
                                :timeout-seconds (or cfg.timeout-seconds DEFAULT-TIMEOUT-SECONDS)
                                :started-at-ms (clock.monotonic-ms)
                                :artifact-checkpoint-seconds cfg.artifact-checkpoint-seconds
                                :max-turns cfg.max-turns
                                :max-tool-calls cfg.max-tool-calls
                                :background? opts.background?
                                :collect opts.collect})]
          (append-local-event! run {:type :subagent-start :task task
                                    :timeout-seconds run.timeout-seconds})
          (when run.repeated-timeout-warning
            (append-local-event! run {:type :warning
                                      :summary (repeated-timeout-warning-text
                                                 run.repeated-timeout-warning)}))
          (let [(ok? err) (pcall start-child! run bin sys-path routing child-policy)]
            (when (not ok?)
              (set run.job.quiet? true)
              (finish! run nil err)))
          run))))

(fn run-agent [cfg agent task requested-cwd cwd physical-cwd ctx ?yield-fn]
  "Blocking launch: pump the run's child to completion, yielding between
   passes. A cancellation raised by the yield cancels and reaps the child
   before it propagates."
  (let [(run err-result) (launch! cfg agent task requested-cwd cwd physical-cwd ctx)]
    (if (not run)
        err-result
        (do
          (while (not (pump! run))
            (if ?yield-fn
                (let [(ok? err) (pcall ?yield-fn)]
                  (when (not ok?)
                    (reap! [run])
                    (error err 0)))
                (clock.sleep-ms TICK-MS)))
          run.job.outcome))))

(fn launch-background [cfg agent task requested-cwd cwd physical-cwd ctx collect-mode]
  (if (>= (runs.active-count) MAX-BACKGROUND-RUNS)
      (result "cannot launch background subagent: active run cap (4) reached" true)
      (let [(run err-result) (launch! cfg agent task requested-cwd cwd physical-cwd ctx
                                      {:background? true :collect collect-mode})]
        (if (not run)
            err-result
            run.job.finished?
            (result (.. "cannot start background subagent: "
                        (tostring (?. run :details :error)))
                    true)
            (do
              (runs.attach-job! run.id)
              (result (.. "Background subagent started: " run.id
                          (if run.repeated-timeout-warning
                              (.. "\nWarning: "
                                  (repeated-timeout-warning-text
                                    run.repeated-timeout-warning))
                              ""))
                      false {:run-id run.id :background? true
                             :collect collect-mode
                             :repeated-timeout-warning run.repeated-timeout-warning}))))))

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
  (let [seconds (or agent.timeout-seconds DEFAULT-TIMEOUT-SECONDS)
        parts [(.. (tostring seconds) "s" (if agent.timeout-seconds "" " default"))]]
    (when agent.max-turns
      (table.insert parts (.. "turns=" (tostring agent.max-turns))))
    (when agent.max-tool-calls
      (table.insert parts (.. "tools=" (tostring agent.max-tool-calls))))
    (table.concat parts ",")))

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
                                    (pad "timeout" 16) " description"))
            (table.insert lines (.. (pad "----" 24) " "
                                    (pad "-----" 8) " "
                                    (pad "--------------" 24) " "
                                    (pad "-------" 16) " -----------"))
            (each [_ a (ipairs shown)]
              (table.insert lines
                (.. (pad (agent-key a) 24) " "
                    (pad (tostring (or a.scope :unknown)) 8) " "
                    (pad (provider-model-status a) 24) " "
                    (pad (timeout-status a) 16) " "
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

(fn artifact-label [run]
  (let [ms (or run.time-to-first-artifact-ms
               (and run.details run.details.time-to-first-artifact-ms))]
    (if ms
        (if (< ms 1000)
            (.. (tostring ms) "ms")
            (.. (tostring (math.floor (/ ms 1000))) "s"))
        run.no-artifact-checkpoint-exceeded?
        "none!"
        "-")))

(fn run-status-label [run]
  "Use the parent-facing outcome vocabulary without changing durable status
   symbols that callers already consume through structured introspection."
  (if run.display-status
      (tostring run.display-status)
      run.budget-limited? "budget-limited"
      (= run.status :completed) "done"
      (tostring (or run.status :unknown))))

(fn run-count-label [run]
  (.. (tostring (or run.turn-count 0)) "/" (tostring (or run.tool-call-count 0))
      " " (artifact-label run)))

(fn render-run-table [rows]
  (let [lines ["```text"
               (.. (pad "id" 12) " "
                   (pad "agent" 16) " "
                   (pad "status" 14) " "
                   (pad "elapsed" 8) " "
                   (pad "turns/tools/art" 16) " task")
               (.. (pad "--" 12) " "
                   (pad "-----" 16) " "
                   (pad "------" 14) " "
                   (pad "-------" 8) " "
                   (pad "---------------" 16) " ----")]]
    (each [_ r (ipairs rows)]
      (table.insert lines
        (.. (pad r.id 12) " "
            (pad r.agent 16) " "
            (pad (run-status-label r) 14) " "
            (pad (duration-label r) 8) " "
            (pad (run-count-label r) 16) " "
            (fit (or r.task-summary "") 72))))
    (table.insert lines "```")
    (table.concat lines "\n")))

(fn latest-runs []
  (let [all (runs.runs)
        out []
        seen {}
        active (runs.active-runs)
        start (math.max 1 (- (length all) 9))]
    (each [_ run (ipairs active)]
      (table.insert out (sanitize-run! run))
      (tset seen run.id true))
    (for [i start (length all)]
      (let [run (. all i)]
        (when (and run (not (. seen run.id)))
          (table.insert out (sanitize-run! run))
          (tset seen run.id true))))
    out))

(fn event-label [ev]
  (let [typ (tostring (or ev.type "event"))
        summary (or ev.summary ev.error ev.name "")]
    (if (= (tostring summary) "") typ (.. typ ": " (fit summary 96)))))

(fn append-event-tail! [lines rows]
  (var any? false)
  (each [_ r (ipairs rows)]
    (let [events (or r.events [])]
      (when (> (length events) 0)
        (when (not any?)
          (set any? true)
          (table.insert lines "")
          (table.insert lines "Latest events:"))
        (let [last (. events (length events))]
          (table.insert lines (.. "- " r.id " " (event-label last)))))))
  any?)

(fn append-timeout-warnings! [lines rows]
  (var any? false)
  (each [_ run (ipairs rows)]
    (when run.repeated-timeout-warning
      (when (not any?)
        (set any? true)
        (table.insert lines "")
        (table.insert lines "Repeated timeout warnings:"))
      (let [warning run.repeated-timeout-warning]
        (table.insert lines
                      (.. "- " run.id ": " (repeated-timeout-warning-text warning))))))
  any?)

(fn render-subagent-runs []
  (let [active-count (runs.active-count)
        rows (latest-runs)
        lines [(.. "# Subagent runs (" active-count " active)") ""]]
    (if (= (length rows) 0)
        (table.insert lines "No subagent runs recorded yet.")
        (do
          (table.insert lines (render-run-table rows))
          (append-event-tail! lines rows)
          (append-timeout-warnings! lines rows)))
    (table.insert lines "")
    (table.insert lines "Blocking is the default; set `background: true` to return immediately with a run id.")
    (table.insert lines "Background completions are queued as follow-ups and do not start a turn automatically.")
    (table.insert lines "Use `/subagents show RUN_ID` to inspect a stored result and details.")
    (table.insert lines "Use `/subagents usage [RUN_ID]` to see token usage per run and workflow totals.")
    (table.insert lines "Use `/subagents steer RUN_ID NOTE` to steer an active child at its next turn boundary.")
    (table.insert lines "Use `/subagents cancel RUN_ID` to cancel an active child, or `/subagents cancel` for all active runs.")
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
      (each [_ key (ipairs usage-util.USAGE-FIELDS)]
        (let [v (. view.usage key)]
          (when (not= v nil)
            (table.insert lines (.. "- " (tostring key) ": " (tostring v))))))
      (when view.turns
        (table.insert lines (.. "- turns: " (tostring view.turns))))
      (table.insert lines (.. "- source: " (tostring (or view.source :unknown))
                              (if (= view.complete? false) " (partial)" "")))
      (table.insert lines (.. "- provenance: " (usage-provenance-note view))))))

(fn append-transcript! [lines run]
  "Render the retained canonical event stream directly; it is the same bounded
   JSONL-derived progress data used by subagent workspaces, not a new format."
  (let [events (or run.events [])]
    (when (> (length events) 0)
      (table.insert lines "")
      (table.insert lines (if (= run.status :running)
                              "Live activity:"
                              "Transcript:"))
      (each [_ ev (ipairs events)]
        (table.insert lines (.. "- " (event-label ev)))))))

(fn render-run-details [run]
  (if (not run)
      nil
      (let [lines [(.. "# Subagent " run.id)
                   ""
                   (.. "- agent: " run.agent)
                   (.. "- status: " (run-status-label run))
                   (.. "- raw-status: " (tostring run.status))
                   (.. "- elapsed: " (duration-label run))
                   (.. "- turn-count: " (tostring (or run.turn-count 0)))
                   (.. "- tool-call-count: " (tostring (or run.tool-call-count 0)))
                   (.. "- background: " (tostring (not (not run.background?))))
                   (.. "- collect: " (tostring (or run.collect :summary)))
                   (.. "- cwd: " (or run.cwd ""))
                   (.. "- task: " (or run.task-summary ""))]]
        (table.insert lines (.. "- time-to-first-artifact-ms: "
                                (if run.time-to-first-artifact-ms
                                    (tostring run.time-to-first-artifact-ms)
                                    "none yet")))
        (when run.max-turns
          (table.insert lines (.. "- max-turns: " (tostring run.max-turns))))
        (when run.max-tool-calls
          (table.insert lines (.. "- max-tool-calls: " (tostring run.max-tool-calls))))
        (when run.budget-finalization-requested?
          (table.insert lines "- budget-finalization-requested: true"))
        (when run.budget-finalization-reason
          (table.insert lines (.. "- budget-finalization-reason: "
                                  (tostring run.budget-finalization-reason))))
        (when run.final-answer-produced?
          (table.insert lines "- final-answer-produced: true"))
        (when run.repeated-timeout-warning
          (let [warning run.repeated-timeout-warning]
            (table.insert lines (.. "- repeated-timeout-warning-count: "
                                    (tostring warning.count)))
            (table.insert lines (.. "- repeated-timeout-warning: " warning.suggestion))
            (when warning.history-truncated?
              (table.insert lines "- repeated-timeout-history-truncated: true"))))
        (when (> (length (or run.repeated-inspection-warnings [])) 0)
          (table.insert lines "- repeated-inspection-warnings:")
          (each [_ warning (ipairs run.repeated-inspection-warnings)]
            (table.insert lines (.. "  - " (tostring (or warning.summary
                                                       warning.fingerprint
                                                       "warning"))))))
        (when run.first-artifact-kind
          (table.insert lines (.. "- first-artifact-kind: "
                                  (tostring run.first-artifact-kind))))
        (when run.first-artifact-summary
          (table.insert lines (.. "- first-artifact-summary: "
                                  (tostring run.first-artifact-summary))))
        (when run.no-artifact-checkpoint-exceeded?
          (table.insert lines "- no-artifact-checkpoint-exceeded: true"))
        (when run.details
          (table.insert lines "")
          (table.insert lines "Details:")
          (each [_ key (ipairs [:duration-ms :exit-code :signal :timed-out?
                                :provider :model :stop-reason :event-count
                                :event-error-count :child-exit])]
            (let [v (. run.details key)]
              (when (not= v nil)
                (table.insert lines (.. "- " (tostring key) ": " (tostring v)))))))
        (append-usage-lines! lines run)
        (append-transcript! lines run)
        (when (not (blank? run.result))
          (table.insert lines "")
          (table.insert lines "Result:")
          (table.insert lines run.result))
        (when (and run.details (not (blank? run.details.output-tail)))
          (table.insert lines "")
          (table.insert lines "Process output tail:")
          (table.insert lines run.details.output-tail))
        (table.concat lines "\n"))))

(fn usage-cell [usage key]
  (human-tokens (and usage (. usage key))))

(fn render-usage-table [rows]
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
    (each [_ r (ipairs rows)]
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
          (each [_ key (ipairs usage-util.USAGE-FIELDS)]
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
      (let [run (runs.find ?run-id)]
        (or (render-run-details run) (.. "No subagent run named " ?run-id)))
      (let [rows (latest-runs)
            lines [(.. "# Subagent usage (" (length rows) " recent)") ""]]
        (if (= (length rows) 0)
            (table.insert lines "No subagent runs recorded yet.")
            (table.insert lines (render-usage-table rows)))
        (table.concat lines "\n"))))

(fn subagents-command-handler [args ctx api]
  (let [trimmed (trim args)
        cmd (string.lower (or (string.match trimmed "^(%S+)") ""))]
    (if (= cmd "show")
        (let [run-id (string.match trimmed "^%S+%s+(%S+)%s*$")
              run (and run-id (runs.find run-id))]
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
              run (and run-id (active-record run-id))]
          (if run
              (do
                (request-cancel! run)
                (api.emit {:type :assistant-text
                           :text (.. "Requested cancellation for " run-id ".")}))
              run-id
              (api.emit {:type :assistant-text
                         :text (.. "No active subagent run named " run-id)})
              (let [active (runs.active-records)
                    n (length active)]
                (if (= n 0)
                    (api.emit {:type :assistant-text
                               :text "No active subagent runs to cancel."})
                    (do
                      (each [_ r (ipairs active)] (request-cancel! r))
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
              (let [run (runs.request-steer! run-id note :user)]
                (if run
                    (api.emit {:type :assistant-text
                               :text (.. "Queued steering for " run-id ": "
                                         (fit note 120))})
                    (api.emit {:type :assistant-text
                               :text (.. "No active subagent run named " run-id)})))))
        (api.emit {:type :assistant-text
                   :text (render-subagent-runs)}))))

(fn subagent-status-render [_ctx]
  (let [n (runs.active-count)]
    (when (> n 0)
      {:text (.. "subagent:" n " running")
       :style :status})))

(fn subagent-snapshot [_ctx]
  (let [snap (runs.snapshot)]
    (each [_ r (ipairs (or snap.active-runs []))] (sanitize-run! r))
    (each [_ r (ipairs (or snap.runs []))] (sanitize-run! r))
    snap))

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
        (let [lines ["Available subagents (activate `subagent` through `tool_search` first):"
                     "Subagent policy:"
                     "- Before launch, run action=models and pass an exact listed provider/model pair."
                     "- Delegate a self-contained task with cwd, expected artifact, and short bounds; parallelize only independent work."
                     "- After failure, inspect or steer the retained run instead of repeating it unchanged; verify child evidence before reporting completion."]
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

(fn parse-artifact-checkpoint [raw]
  "Coerce an optional no-progress checkpoint budget in seconds."
  (let [n (tonumber raw)]
    (if (and n (> n 0)) n nil)))

(fn parse-positive-budget [raw]
  (let [n (tonumber raw)]
    (if (and n (> n 0)) n nil)))

(fn with-call-timeout [cfg args]
  (let [out {}]
    (each [k v (pairs cfg)] (tset out k v))
    (set out.timeout-seconds (effective-timeout cfg args))
    (set out.artifact-checkpoint-seconds
         (parse-artifact-checkpoint (or args.artifact-checkpoint-seconds
                                        args.artifact_checkpoint_seconds)))
    (set out.max-turns (or (parse-positive-budget (or args.max-turns
                                                      args.max_turns))
                           cfg.max-turns))
    (set out.max-tool-calls
         (or (parse-positive-budget (or args.max-tool-calls
                                        args.max_tool_calls))
             cfg.max-tool-calls))
    ;; Explicit per-call routing wins over named-agent frontmatter. This lets a
    ;; caller use the authenticated model inventory without rewriting an agent
    ;; definition and makes the routing visible in the launch tool call.
    (when (present? args.provider) (set out.provider args.provider))
    (when (present? args.model) (set out.model args.model))
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
   :artifact-checkpoint-seconds nil
   :max-turns nil
   :max-tool-calls nil
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
  "Allow background jobs only when the run's presenter pumps runtime ticks while
   idle, so a detached child is reaped instead of stranding. The capability is
   read from the presenter register kind (:idle-ticks?) rather than a name
   denylist. An unresolved presenter (no name in ctx) is treated as capable to
   preserve the historical default for embedders."
  (let [name (tostring (or (?. ctx :state :opts :presenter) ""))]
    (if (= name "")
        true
        (do
          (var supported? false)
          (each [_ p (ipairs (presenter-registry.list)) &until supported?]
            (when (and (= (tostring p.name) name) p.idle-ticks?)
              (set supported? true)))
          supported?))))


(fn wait-for-run [run-id args ?yield-fn]
  (let [budget (or (parse-timeout-arg args.timeout-seconds) 30)
        deadline (+ (clock.monotonic-ms) (* budget 1000))]
    (var run (runs.find run-id))
    (while (and run (= run.status :running)
                (< (clock.monotonic-ms) deadline))
      (pump-background-jobs!)
      (if ?yield-fn (?yield-fn) (clock.sleep-ms 10))
      (set run (runs.find run-id)))
    (if (not run)
        (result (.. "No subagent run named " run-id) true
                {:run-id run-id :found? false})
        (= run.status :running)
        (result (.. "Wait timed out; " run-id " is still running.") false
                {:run (sanitize-run! run) :timed-out? true})
        (result (or (render-run-details run) "") false
                {:run (sanitize-run! run) :timed-out? false}))))

(fn authenticated-models-result [api ?yield-fn]
  "Refresh configured provider catalogs and return exact launch routing pairs."
  (let [opts {:dynamic-mode :refresh}
        _yield (when ?yield-fn (set opts.yield ?yield-fn))
        providers (api.models.inspect opts {:catalog? true})
        rows []
        unavailable []
        lines ["# Authenticated subagent models" ""]]
    (each [_ provider (ipairs providers)]
      (when provider.available?
        (if (= provider.catalog.status :fallback)
            (table.insert unavailable
                          (.. (tostring provider.name)
                              " (catalog refresh failed; fallback IDs omitted)"))
            (each [_ model (ipairs (or provider.models []))]
              (let [row {:provider provider.name
                         :model model.id
                         :canonical-id (.. (tostring provider.name) "/"
                                           (tostring model.id))
                         :default? model.default?
                         :source model.source
                         :catalog-status provider.catalog.status}]
                (table.insert rows row))))))
    (table.sort rows #( < $1.canonical-id $2.canonical-id))
    (if (= (length rows) 0)
        (table.insert lines "No models are available from authenticated or authless providers.")
        (do
          (table.insert lines "Use one exact pair below and pass both `provider` and `model` on the launch call:")
          (each [_ row (ipairs rows)]
            (table.insert lines
                          (.. "- " row.canonical-id
                              (if row.default? " (default)" ""))))))
    (when (> (length unavailable) 0)
      (table.insert lines "")
      (table.insert lines "Not offered because the authenticated catalog could not be verified:")
      (each [_ warning (ipairs unavailable)]
        (table.insert lines (.. "- " warning))))
    (result (table.concat lines "\n") false
            {:models rows :model-count (length rows)
             :unavailable-providers unavailable})))

(fn review-worktree-result [args]
  (let [requested-cwd (or args.cwd (path.cwd))
        cwd (absolute-cwd requested-cwd)
        count (or args.worktree-count 1)]
    (if (not (path.dir-exists? cwd))
        (result (.. "cwd does not exist: " requested-cwd) true)
        ;; The four-worktree bound is global across calls, not per call;
        ;; otherwise repeated review-worktrees actions accumulate trees.
        (< 4 (+ (length (runs.review-worktrees)) count))
        (let [tracked (length (runs.review-worktrees))]
          (result (.. "review worktree limit reached: " (tostring tracked)
                      " tracked, " (tostring count)
                      " more requested (max 4 total); run cleanup-review-worktrees first")
                  true {:tracked tracked :requested count :limit 4}))
        (let [(records err) (worktrees.create cwd args.ref count)]
          (if err
              (result err true {:cwd cwd})
              (do
                (runs.add-review-worktrees! records)
                (result (.. "Created " (tostring (length records))
                            " detached review worktree(s). Launch the ordinary "
                            "read-only reviewer or scout subagent with one returned cwd."
                            ) false
                        {:worktrees records})))))))

(fn cleanup-review-worktrees-result []
  (let [removed [] failures []]
    (each [_ record (ipairs (runs.review-worktrees))]
      (let [(ok err) (worktrees.cleanup record)]
        (if ok
            (do (runs.remove-review-worktree! record.path)
                (table.insert removed record.path))
            (table.insert failures {:path record.path :error err}))))
    (result (.. "Removed " (tostring (length removed))
                " unchanged review worktree(s).")
            (> (length failures) 0)
            {:removed removed :failures failures
             :remaining (runs.review-worktrees)})))

(fn management-execute [args ctx ?yield-fn api]
  (let [action (string.lower (tostring (or args.action "")))
        run-id args.run-id]
    (if (= action "models")
        (authenticated-models-result api ?yield-fn)
        (= action "review-worktrees")
        (review-worktree-result args)
        (= action "cleanup-review-worktrees")
        (cleanup-review-worktrees-result)
        (= action "list")
        (result (render-subagent-runs) false (subagent-snapshot nil))
        (= action "show")
        (if (not (present? run-id))
            (result "action 'show' requires 'run-id'" true)
            (let [run (runs.find run-id)]
              (if run
                  (result (render-run-details run) false {:run (sanitize-run! run)})
                  (result (.. "No subagent run named " run-id) true
                          {:run-id run-id :found? false}))))
        (= action "usage")
        (if (present? run-id)
            (let [run (runs.find run-id)]
              (if run
                  (do
                    (sanitize-run! run)
                    (result (render-run-details run) false
                            {:run run :usage (run-usage-view run)}))
                  (result (.. "No subagent run named " run-id) true
                          {:run-id run-id :found? false})))
            (let [rows (latest-runs)
                  views []]
              (each [_ r (ipairs rows)]
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
                      {:runs views :active-count (runs.active-count)})))
        (= action "wait")
        (if (not (present? run-id))
            (result "action 'wait' requires 'run-id'" true)
            (wait-for-run run-id args ?yield-fn))
        (= action "steer")
        (if (or (not (present? run-id)) (not (present? args.note)))
            (result "action 'steer' requires 'run-id' and 'note'" true)
            (let [run (runs.request-steer! run-id args.note :agent)]
              (if run
                  (result (.. "Queued steering for " run-id ".") false
                          {:run (sanitize-run! (runs.find run.id))})
                  (result (.. "No active subagent run named " run-id) true))))
        (= action "cancel")
        (if (not (present? run-id))
            (result "action 'cancel' requires 'run-id'" true)
            (let [job (runs.job run-id)
                  run (active-record run-id)]
              (if job
                  (do (set job.job.quiet? true)
                      (reap! [job])
                      (result (.. "Cancelled " run-id ".") false
                              {:run (sanitize-run! (runs.find run-id))}))
                  run
                  ;; A blocking run's own driver cancels and reaps it.
                  (do (request-cancel! run)
                      (result (.. "Requested cancellation for " run-id ".") false
                              {:run (sanitize-run! (runs.find run-id))}))
                  (result (.. "No active subagent run named " run-id) true))))
        (= action "cancel-all")
        (let [jobs (runs.jobs)
              n (length jobs)]
          (when (> n 0) (shutdown-background-jobs! true))
          ;; A blocking subagent is cancelled through its owning turn.
          (when (and ctx (> (runs.active-count) 0))
            (set ctx.cancel-requested? true))
          (result (if (> n 0)
                      (.. "Cancelled " n " background subagent run(s).")
                      "No active background subagent runs to cancel.") false
                  {:cancelled n :active-count (runs.active-count)}))
        (= action "remove")
        (if (not (present? run-id))
            (result "action 'remove' requires 'run-id'" true)
            (let [(removed err) (runs.remove! run-id)]
              (if removed
                  (result (.. "Removed " run-id ".") false {:run-id run-id})
                  (result (.. "Cannot remove " run-id ": " err) true
                          {:run-id run-id :reason err}))))
        (= action "retry")
        (if (not (present? run-id))
            (result "action 'retry' requires 'run-id'" true)
            (let [old (runs.record run-id)]
              (if (not old)
                  (result (.. "No subagent run named " run-id) true)
                  (= old.status :running)
                  (result (.. run-id " is still running") true)
                  (not (and old.background? old.cfg old.task))
                  (result "retry is available only for retained background runs" true)
                  (>= (runs.active-count) MAX-BACKGROUND-RUNS)
                  (result "cannot retry subagent: active run cap (4) reached" true)
                  (not (background-supported? ctx))
                  (result "background subagents require a ticking presenter (use the TUI)" true)
                  (let [r (launch-background old.cfg old.agent old.task
                                             old.requested-cwd old.cwd old.physical-cwd
                                             ctx (or old.collect :summary))]
                    (when r.details
                      (set r.details.retry-of run-id)
                      (let [retried (runs.record r.details.run-id)]
                        (when retried (set retried.retry-of run-id))))
                    r))))
        (= action "clear")
        (if (> (runs.active-count) 0)
            (result "cannot clear subagent history while runs are active; cancel them first" true)
            (let [n (length (runs.runs))]
              (runs.clear!)
              (result "Cleared subagent run history." false {:cleared n})))
        (= action "reset")
        (let [jobs (runs.jobs)
              cancelled (length jobs)]
          (when (> cancelled 0) (shutdown-background-jobs! true))
          (if (> (runs.active-count) 0)
              (do (when ctx (set ctx.cancel-requested? true))
                  (result "blocking subagent cancellation requested; reset again after it exits" true
                          {:cancelled cancelled
                           :active-count (runs.active-count)}))
              (let [cleared (length (runs.runs))]
                (runs.clear!)
                (result "Cancelled active jobs and cleared subagent history." false
                        {:cancelled cancelled :cleared cleared}))))
        (result (.. "unknown subagent action: " action) true))))

(fn execute [args ctx ?yield-fn api]
  (let [{: task : cwd} args]
    (if (present? args.action)
        (management-execute args ctx ?yield-fn api)
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
                          (>= (runs.active-count) MAX-BACKGROUND-RUNS)
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
  ;; /reload is a cancel point for detached children: cancel and reap them
  ;; before registering the new behavior.
  (shutdown-background-jobs!)
  (runs.reconcile-background!)
  (api.on :runtime-tick (fn [_ev]
                          (pump-background-jobs!)
                          (runs.reconcile-background!)))
  (api.on :agent-shutdown (fn [_ev] (shutdown-background-jobs!)))
  (api.on :reset-conversation
          (fn [ev]
            ;; Only /new is a hard process boundary. Resume and handoff also
            ;; reset presenter content but must not silently destroy jobs.
            (when (= ev.reason :new)
              (shutdown-background-jobs! true)
              (runs.reconcile-background!)
              (runs.clear!))))
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
                      "`timeout-seconds`, `max-turns`, or `max-tool-calls` "
                      "to explicit short budgets when partial progress would "
                      "still be useful. The child normally returns final text; "
                      "failures and empty successful results return diagnostic "
                      "text with details, including provider/model sources. "
                      "Run details expose time-to-first-artifact when child progress events reveal the first useful tool/text/error artifact, plus budget counters and repeated-inspection warnings. "
                      "Set `background: true` to launch explicitly without "
                      "blocking; completion is queued as a follow-up and the "
                      "full stored result is available through `/subagents show`. "
                      "Background jobs are read-only and never auto-start a turn. "
                      "Before launching, use action=models to refresh model "
                      "catalogs for authenticated providers, select an exact "
                      "provider/model pair from the result, and pass both "
                      "fields explicitly on the launch. Per-call routing "
                      "overrides named-agent frontmatter. Do not guess model "
                      "IDs or rely on inherited routing. Use action=list/show/"
                      "usage/wait/steer/cancel/cancel-all/remove/retry/clear/"
                      "reset to inspect and manage stored "
                      "runs, including per-run and workflow token usage, "
                      "directly; management actions do "
                      "not launch a child. When several "
                      "subagent tool calls in the same assistant turn; fen may "
                      "run them concurrently, capped at 4. Named agents are "
                      "defined as markdown files under .fen/agents/ (project), "
                      "~/.config/fen/agents/ (user), or bundled with fen.")
     :parameters {:type :object
                  :properties {:action {:type :string
                                        :enum ["models" "review-worktrees" "cleanup-review-worktrees" "list" "show" "usage" "wait" "steer" "cancel" "cancel-all"
                                               "remove" "retry" "clear" "reset"]
                                        :description "Use `models` before a launch to refresh exact models. `review-worktrees` creates 1–4 detached sibling worktrees for ordinary read-only subagent launches; `cleanup-review-worktrees` removes only unchanged worktrees it created. Other values inspect or manage runs."}
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
                                     :description "Working directory for the child or review-worktree source; validated to exist. Defaults to the current directory."}
                               :ref {:type :string
                                     :description "Git revision for action=review-worktrees; defaults to HEAD and is checked out detached."}
                               :worktree-count {:type :number
                                                :description "Number of detached sibling review worktrees to create (1–4) for action=review-worktrees."}
                               :model {:type :string
                                       :description "Exact model id selected from action=models. Pass explicitly with `provider` on every launch; overrides named-agent frontmatter."}
                               :provider {:type :string
                                          :description "Exact provider selected from action=models. Pass explicitly with `model` on every launch; overrides named-agent frontmatter."}
                               :timeout-seconds {:type :number
                                                 :description "For launches, set a shorter positive child timeout capped by policy. For action=wait, set the polling budget (default 30 seconds)."}
                               :max-turns {:type :number
                                           :description "Optional launch budget for completed child LLM turns. When reached before a final artifact, the parent strongly steers the child to return findings now."}
                               :max-tool-calls {:type :number
                                                :description "Optional launch budget for child tool calls. When reached before a final artifact, the parent strongly steers the child to return findings now."}
                               :artifact-checkpoint-seconds {:type :number
                                                             :description "Optional no-progress budget for launches: when the child produces no useful artifact within this many seconds, the parent strongly steers it to return findings now, like max-turns/max-tool-calls. Run details and /subagents show expose time-to-first-artifact or an explicit no-artifact-yet state."}
                               :background {:type :boolean
                                            :description "Run detached and return immediately with a run id. Defaults to false."}
                               :collect {:type :string
                                         :enum ["summary" "full"]
                                         :description "For background completion follow-ups, queue a compact summary (default) or the full final result."}}}
     :execute (fn [args ctx ?yield-fn]
                (execute args ctx ?yield-fn api))})
  true)

M
