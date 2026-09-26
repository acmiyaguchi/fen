;; Subagent run records: start, events, usage, steering queue, and finish.
;;
;; Reloadable behavior over the persistent data table in
;; fen.extensions.subagent.state, resolved at call time so /reload and tests
;; always see the live table.

(local text (require :fen.util.text))
(local usage-util (require :fen.util.usage))

(local M {})
(local MAX-RUNS 20)
(local MAX-EVENTS 50)
(local MAX-EVENT-ERRORS 20)
(local MAX-STEERING-NOTES 20)
(local SUMMARY-BYTES 96)
;; Launch inputs and the live child job stay out of public copies.
(local PRIVATE-KEYS {:job true :cfg true :task true :task-fingerprint true
                     :started-at-ms true :inspection-fingerprints true})

(fn S []
  (or (. (require :fen.extensions.subagent.state) :data)
      (error "subagent: retained run state predates this version; restart fen")))

(fn copy [tbl]
  (let [out {}]
    (each [k v (pairs (or tbl {}))]
      (tset out k v))
    out))

(fn copy-list [xs]
  (let [out []]
    (each [_ v (ipairs (or xs []))]
      (table.insert out (if (= (type v) :table) (copy v) v)))
    out))

(fn copy-run [run]
  (let [out {}]
    (each [k v (pairs (or run {}))]
      (when (not (. PRIVATE-KEYS k))
        (tset out k v)))
    ;; Keep the internal lifecycle symbol stable while exporting the compact
    ;; parent-facing outcome used by listings and agentic introspection. A
    ;; terminal failure stays visible even when budget limited; a run that
    ;; produced a final answer displays as done even if it hit a budget.
    (set out.display-status (if (or (= run.status :failed)
                                    (= run.status :timed-out))
                                run.status
                                (and run.budget-limited?
                                     (not run.final-answer-produced?))
                                :budget-limited
                                (= run.status :completed) :done
                                run.status))
    (set out.events (copy-list run.events))
    (set out.event-errors (copy-list run.event-errors))
    (set out.steering-notes (copy-list run.steering-notes))
    (set out.pending-steering (copy-list run.pending-steering))
    (when run.first-artifact (set out.first-artifact (copy run.first-artifact)))
    (when (and (= run.status :running)
               run.artifact-checkpoint-seconds
               (not run.first-artifact))
      (set out.no-artifact-checkpoint-exceeded?
           (>= (os.difftime (os.time) run.started-at)
               run.artifact-checkpoint-seconds)))
    (when run.details
      (let [d (copy run.details)]
        (when (= (type d.usage) :table) (set d.usage (copy d.usage)))
        (when (= (type d.usage-provenance) :table)
          (set d.usage-provenance (copy d.usage-provenance)))
        (when (= (type d.repeated-inspection-warnings) :table)
          (set d.repeated-inspection-warnings
               (copy-list d.repeated-inspection-warnings)))
        (set out.details d)))
    (when run.usage-acc (set out.usage-acc (usage-util.copy-usage-acc run.usage-acc)))
    (when run.repeated-inspection-warnings
      (set out.repeated-inspection-warnings
           (copy-list run.repeated-inspection-warnings)))
    (when run.repeated-timeout-warning
      (set out.repeated-timeout-warning (copy run.repeated-timeout-warning)))
    out))

(fn find-run [id]
  (let [state (S)]
    (or (. state.active id)
        (accumulate [found nil _ r (ipairs state.runs) &until found]
          (when (= r.id id) r)))))

(fn trim-list! [xs max]
  (while (> (length xs) max)
    (table.remove xs 1)))

(fn active-count []
  (accumulate [n 0 _ _run (pairs (. (S) :active))] (+ n 1)))

(fn trim-runs! []
  (let [state (S)]
    (var done? false)
    (while (and (> (length state.runs) MAX-RUNS) (not done?))
      (let [remove-index (accumulate [found nil i run (ipairs state.runs) &until found]
                           (when (not (. state.active run.id)) i))]
        (if remove-index
            (let [evicted (table.remove state.runs remove-index)]
              (set state.runs-truncated? true)
              (when evicted.task-fingerprint
                (tset state.truncated-fingerprints evicted.task-fingerprint true)))
            (set done? true))))))

(fn M.repeated-timeout-warning [task-fingerprint]
  "Return bounded retained-history telemetry for an identical launch.
   Count consecutive no-artifact timeouts since this fingerprint last produced
   an artifact; the launch about to start is included in `count`."
  (let [state (S)]
    (var prior-count 0)
    (var cleared? false)
    (for [i (length state.runs) 1 -1]
      (let [run (. state.runs i)]
        (when (and (not cleared?) (= run.task-fingerprint task-fingerprint))
          (if run.first-artifact
              (set cleared? true)
              (when (= run.status :timed-out)
                (set prior-count (+ prior-count 1)))))))
    (let [count (+ prior-count 1)]
      (when (>= count 3)
        {:count count
         :prior-count prior-count
         :retained-run-limit MAX-RUNS
         :history-truncated? (not (not (. state.truncated-fingerprints task-fingerprint)))
         :suggestion "Steer a retained run or change the plan instead of launching another identical child."}))))

(fn task-summary [task]
  (let [line (text.trim (text.first-line task))]
    (text.truncate-line (if (= line "") "(empty task)" line)
                        SUMMARY-BYTES)))

(fn M.start! [opts]
  (let [state (S)]
    (set state.next-id (+ state.next-id 1))
    (let [seq state.next-id
          id (.. "subagent-" (tostring seq))
          run {:id id
               :seq seq
               :agent (tostring (or opts.agent ""))
               :task opts.task
               :task-summary (task-summary opts.task)
               :task-fingerprint opts.task-fingerprint
               :repeated-timeout-warning opts.repeated-timeout-warning
               :requested-cwd opts.requested-cwd
               :cwd opts.cwd
               :physical-cwd opts.physical-cwd
               :timeout-seconds opts.timeout-seconds
               :cfg opts.cfg
               :status :running
               :started-at (os.time)
               :started-at-ms opts.started-at-ms
               :timed-out? false
               :event-count 0
               :partial-assistant-text? false
               :artifact-checkpoint-seconds opts.artifact-checkpoint-seconds
               :max-turns opts.max-turns
               :max-tool-calls opts.max-tool-calls
               :turn-count 0
               :tool-call-count 0
               :budget-finalization-requested? false
               :budget-limited? false
               :final-answer-produced? false
               :repeated-inspection-warnings []
               :inspection-fingerprints {}
               :events []
               :event-errors []
               :steering-notes []
               :pending-steering []
               :background? (not (not opts.background?))
               :collect (or opts.collect :summary)}]
      (table.insert state.runs run)
      (tset state.active id run)
      (trim-runs!)
      run)))

(fn M.accumulate-usage! [id usage ?source]
  "Fold one provider usage report (an :llm-end turn) into a run's durable
   usage accumulator, so completed-turn usage survives event retention and
   runs that end without a `result`."
  (let [run (find-run id)
        canon (usage-util.canonical-usage usage)]
    (when (and run canon)
      (when (= run.usage-acc nil)
        (set run.usage-acc {:totals {} :provenance {} :turns 0 :source :events}))
      (let [acc run.usage-acc
            prov (usage-util.usage-provenance usage (or ?source :provider-reported))]
        (set acc.turns (+ (or acc.turns 0) 1))
        (each [k v (pairs canon)]
          (tset acc.totals k (+ (or (. acc.totals k) 0) v))
          (tset acc.provenance k
                (if (or (= (. prov k) :estimated) (= (. acc.provenance k) :estimated))
                    :estimated
                    :provider-reported)))))
    run))

(fn M.mark-first-artifact! [id artifact]
  "Record the first useful artifact/progress signal for a run exactly once."
  (let [run (find-run id)]
    (when (and run (not run.first-artifact))
      (let [rec (copy artifact)]
        (set run.first-artifact rec)
        (set run.time-to-first-artifact-ms rec.elapsed-ms)
        (set run.first-artifact-kind rec.kind)
        (set run.first-artifact-summary rec.summary)))
    run))

(fn M.finish! [id status ?details]
  (let [state (S)
        run (. state.active id)
        details (or ?details {})]
    (when run
      (set run.status status)
      (set run.ended-at (os.time))
      (set run.duration-ms details.duration-ms)
      (set run.exit-code details.exit-code)
      (set run.signal details.signal)
      (set run.timed-out? (not (not details.timed-out?)))
      (set run.error details.error)
      (set run.result details.result)
      (when run.time-to-first-artifact-ms
        (set details.time-to-first-artifact-ms run.time-to-first-artifact-ms))
      (when run.first-artifact-kind
        (set details.first-artifact-kind run.first-artifact-kind))
      (when run.first-artifact-summary
        (set details.first-artifact-summary run.first-artifact-summary))
      (when run.artifact-checkpoint-seconds
        (set details.artifact-checkpoint-seconds run.artifact-checkpoint-seconds))
      (when run.max-turns (set details.max-turns run.max-turns))
      (when run.max-tool-calls (set details.max-tool-calls run.max-tool-calls))
      (set details.turn-count (or run.turn-count 0))
      (set details.tool-call-count (or run.tool-call-count 0))
      (when run.budget-limited?
        (set details.budget-limited? true))
      (when run.budget-finalization-requested?
        (set details.budget-finalization-requested? true))
      (when run.budget-finalization-reason
        (set details.budget-finalization-reason run.budget-finalization-reason))
      (when run.final-answer-produced?
        (set details.final-answer-produced? true))
      (when (> (length (or run.repeated-inspection-warnings [])) 0)
        (set details.repeated-inspection-warnings
             (copy-list run.repeated-inspection-warnings))
        (set details.repeated-inspection-warning-count
             (length run.repeated-inspection-warnings)))
      (set run.details details)
      ;; An artifact starts a fresh no-mutation streak, so older evictions for
      ;; this fingerprint can no longer make its next warning a lower bound.
      (when run.first-artifact
        (tset state.truncated-fingerprints run.task-fingerprint nil))
      (tset state.active id nil)
      (tset state.jobs id nil)
      (trim-runs!))
    run))

(fn M.active-count []
  (active-count))

(fn M.find [id]
  (let [run (find-run id)]
    (and run (copy-run run))))

(fn M.record [id]
  "Return the private mutable run record for extension behavior."
  (find-run id))

(fn M.active-records []
  "Return private mutable records of active runs in launch order."
  (let [out []]
    (each [_ run (pairs (. (S) :active))] (table.insert out run))
    (table.sort out (fn [a b] (< (or a.seq 0) (or b.seq 0))))
    out))

(fn M.attach-job! [id]
  "Track an active run as a detached background job."
  (let [state (S)
        run (. state.active id)]
    (when run (tset state.jobs id run))
    run))

(fn M.job [id]
  "Return the private mutable background job record for extension behavior."
  (. (S) :jobs id))

(fn M.jobs []
  "Return private mutable background job records in launch order."
  (let [out []]
    (each [_ run (pairs (. (S) :jobs))] (table.insert out run))
    (table.sort out (fn [a b] (< (or a.seq 0) (or b.seq 0))))
    out))

(fn M.append-event! [id ev]
  (let [run (find-run id)]
    (when run
      (set run.event-count (+ (or run.event-count 0) 1))
      (let [stored (copy ev)]
        (set stored.transport-seq run.event-count)
        (when (or (= stored.type :assistant-text)
                  (= stored.type :assistant-text-delta))
          (set run.partial-assistant-text? true))
        (when (= run.events nil) (set run.events []))
        (table.insert run.events stored)
        (trim-list! run.events MAX-EVENTS)))
    run))

(fn M.append-event-error! [id err]
  (let [run (. (S) :active id)]
    (when run
      (when (= run.event-errors nil) (set run.event-errors []))
      (table.insert run.event-errors err)
      (trim-list! run.event-errors MAX-EVENT-ERRORS))
    run))

(fn M.request-steer! [id note ?source]
  "Queue a steering note for an active run; the run's driver sends it to the
   live child. Returns the run, or (values nil :not-active)."
  (let [run (. (S) :active id)]
    (if (not run)
        (values nil :not-active)
        (let [full-note (text.trim (tostring (or note "")))
              rec {:note full-note
                   :summary (task-summary full-note)
                   :source (or ?source :user)
                   :requested-at (os.time)}]
          (table.insert run.steering-notes rec)
          (table.insert run.pending-steering rec)
          (trim-list! run.steering-notes MAX-STEERING-NOTES)
          (M.append-event! id {:type :steering :summary rec.summary :source rec.source})
          run))))

(fn M.take-steering! [id]
  (let [run (. (S) :active id)]
    (when (and run (> (length (or run.pending-steering [])) 0))
      (table.remove run.pending-steering 1))))

(fn M.active-runs []
  (let [out []]
    (each [_ run (ipairs (M.active-records))]
      (table.insert out (copy-run run)))
    out))

(fn M.runs []
  (icollect [_ run (ipairs (. (S) :runs))]
    (copy-run run)))

(fn M.review-worktrees []
  (copy-list (. (S) :review-worktrees)))

(fn M.add-review-worktrees! [records]
  (let [state (S)]
    (each [_ record (ipairs records)]
      (table.insert state.review-worktrees (copy record))))
  (M.review-worktrees))

(fn M.remove-review-worktree! [worktree-path]
  (let [state (S)
        found (accumulate [found nil i record (ipairs state.review-worktrees) &until found]
                (when (= record.path worktree-path) i))]
    (when found (table.remove state.review-worktrees found)))
  (M.review-worktrees))

(fn M.snapshot []
  (let [state (S)]
    {:active-count (active-count)
     :active-runs (M.active-runs)
     :review-worktrees (M.review-worktrees)
     :next-id state.next-id
     :retained-run-limit MAX-RUNS
     :runs-truncated? state.runs-truncated?
     :runs (M.runs)}))

(fn M.reconcile-background! []
  "Finish background runs whose job is no longer tracked. Blocking runs are
   owned by their tool call and are left alone."
  (let [state (S)
        stale []]
    (each [id run (pairs state.active)]
      (when (and run.background? (not (. state.jobs id)))
        (table.insert stale id)))
    (each [_ id (ipairs stale)]
      (M.finish! id :failed
                 {:error "background subagent lost its process handle"}))
    (each [id _job (pairs state.jobs)]
      (when (not (. state.active id))
        (tset state.jobs id nil)))
    (length stale)))

(fn M.remove! [id]
  "Remove one inactive run record. Active runs must be cancelled first."
  (let [state (S)]
    (if (. state.active id)
        (values nil "run is active")
        (let [found (accumulate [found nil i run (ipairs state.runs) &until found]
                      (when (= run.id id) i))
              removed (and found (table.remove state.runs found))]
          (values removed (and (not removed) "run not found"))))))

(fn M.clear! []
  "Clear run records after callers have reaped active jobs. Preserve the
   process-lifetime id sequence so a stale run id cannot name a future child."
  (let [state (S)]
    (set state.runs [])
    (set state.runs-truncated? false)
    (set state.truncated-fingerprints {})
    (set state.active {})
    ;; Keep review worktree ownership records until explicit safe cleanup.
    (set state.jobs {}))
  nil)

(fn M.reset! []
  "Test/startup reset, including the process-lifetime id sequence."
  (let [state (S)]
    (set state.next-id 0))
  (M.clear!))

(set M.copy-run copy-run)

M
