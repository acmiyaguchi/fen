;; Persistent subagent run state.
;;
;; This module is intentionally kept out of the subagent manifest's
;; reload-modules list so /reload can replace behavior while preserving active
;; and recent run records.

(local text (require :fen.util.text))

(local M {})
(local MAX-RUNS 20)
(local MAX-EVENTS 50)

;; Canonical token fields, in display order. `total-tokens` conventionally
;; excludes cache tokens (input+output), matching provider adapters.
(local USAGE-FIELDS [:input :output :cache-read :cache-write :reasoning
                     :total-tokens])
(local MAX-EVENT-ERRORS 20)
(local MAX-STEERING-NOTES 20)
(local SUMMARY-BYTES 96)
(local PRIVATE-KEYS {:handle true :cfg true :routing true :task true
                     :current-task true :bin true :deadline-ms true
                     :started-at-ms true :last-event-status true
                     :sys-path true :out-path true :event-path true
                     :restart-note true})

(local state {:next-id 0
              :runs []
              :active {}
              ;; Background job records intentionally persist across /reload.
              ;; They contain process handles and launch paths, so public copies
              ;; and snapshots must always pass through copy-run.
              :jobs {}})

(fn copy [tbl]
  (let [out {}]
    (each [k v (pairs (or tbl {}))]
      (tset out k v))
    out))

(fn num [v]
  (and (= (type v) :number) v))

(fn pick [usage keys]
  (var found nil)
  (each [_ k (ipairs keys)]
    (when (= found nil)
      (let [v (num (. usage k))]
        (when v (set found v)))))
  found)

(fn canonical-usage [usage]
  "Extract canonical token fields from a provider usage table, tolerating both
   Fennel-cased and provider snake_case keys. Returns a table with any present
   numeric fields plus a derived total, or nil when nothing usable is present.
   Non-token fields such as latency-ms are intentionally ignored."
  (when (= (type usage) :table)
    (let [input (pick usage [:input :input_tokens :input-tokens
                             :prompt_tokens :prompt-tokens])
          output (pick usage [:output :output_tokens :output-tokens
                              :completion_tokens :completion-tokens])
          cache-read (pick usage [:cache-read :cache_read :cached_tokens
                                  :cache_read_input_tokens])
          cache-write (pick usage [:cache-write :cache_write
                                   :cache_creation_input_tokens])
          reasoning (pick usage [:reasoning :reasoning_tokens :reasoning-tokens])
          reported-total (pick usage [:total-tokens :total_tokens :total])
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

(fn copy-usage-acc [acc]
  (when acc
    {:totals (copy acc.totals)
     :provenance (copy acc.provenance)
     :turns acc.turns
     :source acc.source}))

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
    (set out.events (copy-list run.events))
    (set out.event-errors (copy-list run.event-errors))
    (set out.steering-notes (copy-list run.steering-notes))
    (set out.pending-steering (copy-list run.pending-steering))
    ;; Result details are data-only today; copy their top level defensively so
    ;; introspection callers cannot mutate persistent run state.
    (when run.details
      (let [d (copy run.details)]
        (when (= (type d.usage) :table) (set d.usage (copy d.usage)))
        (when (= (type d.usage-provenance) :table)
          (set d.usage-provenance (copy d.usage-provenance)))
        (set out.details d)))
    (when run.usage-acc (set out.usage-acc (copy-usage-acc run.usage-acc)))
    out))

(fn find-run [id]
  (or (. state.active id)
      (let []
        (var found nil)
        (each [_ r (ipairs state.runs)]
          (when (and (not found) (= r.id id))
            (set found r)))
        found)))

(fn trim-list! [xs max]
  (while (> (length xs) max)
    (table.remove xs 1)))

(fn active-count []
  (var n 0)
  (each [_ _run (pairs state.active)]
    (set n (+ n 1)))
  n)

(fn active-run? [run]
  (and run run.id (. state.active run.id)))

(fn trim-runs! []
  (var done? false)
  (while (and (> (length state.runs) MAX-RUNS) (not done?))
    (var remove-index nil)
    (each [i run (ipairs state.runs)]
      (when (and (not remove-index) (not (active-run? run)))
        (set remove-index i)))
    (if remove-index
        (table.remove state.runs remove-index)
        (set done? true))))

(fn task-summary [task]
  (let [line (text.trim (text.first-line task))]
    (text.truncate-line (if (= line "") "(empty task)" line)
                        SUMMARY-BYTES)))

(fn M.start! [opts]
  (set state.next-id (+ state.next-id 1))
  (let [seq state.next-id
        id (.. "subagent-" (tostring seq))
        run {:id id
             :seq seq
             :agent (tostring (or opts.agent ""))
             :task-summary (task-summary opts.task)
             :requested-cwd opts.requested-cwd
             :cwd opts.cwd
             :physical-cwd opts.physical-cwd
             :timeout-seconds opts.timeout-seconds
             :status :running
             :started-at (os.time)
             :ended-at nil
             :duration-ms nil
             :exit-code nil
             :signal nil
             :timed-out? false
             :error nil
             :event-offset 0
             :event-count 0
             :partial-assistant-text? false
             :events []
             :event-errors []
             :restart-count 0
             :steering-notes []
             :pending-steering []
             :background? (not (not opts.background?))
             :collect (or opts.collect :summary)
             :result nil
             :details nil}]
    (table.insert state.runs run)
    (tset state.active id run)
    (trim-runs!)
    run))

(fn M.canonical-usage [usage]
  (canonical-usage usage))

(fn M.accumulate-usage! [id usage ?source]
  "Fold one provider usage report (typically an :llm-end turn) into a run's
   durable usage accumulator. Summed at drain time so completed-turn usage
   survives event-retention truncation and child timeouts that never write a
   final result blob."
  (let [run (find-run id)
        canon (canonical-usage usage)]
    (when (and run canon)
      (when (= run.usage-acc nil)
        (set run.usage-acc {:totals {} :provenance {} :turns 0 :source :events}))
      (let [acc run.usage-acc
            source (or ?source :provider-reported)]
        (set acc.turns (+ (or acc.turns 0) 1))
        (each [k v (pairs canon)]
          (tset acc.totals k (+ (or (. acc.totals k) 0) v))
          (tset acc.provenance k source))))
    run))

(fn M.usage-acc [id]
  "Return a copy of the live usage accumulator for a run, or nil."
  (let [run (find-run id)]
    (and run (copy-usage-acc run.usage-acc))))

(fn M.finish! [id status ?details]
  (let [run (. state.active id)
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
      (set run.details details)
      (tset state.active id nil)
      (trim-runs!))
    run))

(fn M.active-count []
  (active-count))

(fn M.find [id]
  (let [run (find-run id)]
    (and run (copy-run run))))

(fn M.attach-job! [id job]
  "Attach private background process metadata to an active run."
  (let [run (. state.active id)]
    (when run
      (each [k v (pairs job)] (tset run k v))
      (tset state.jobs id run))
    run))

(fn M.job [id]
  "Return the private mutable background job record for extension behavior."
  (. state.jobs id))

(fn M.jobs []
  "Return private mutable background job records in launch order."
  (let [out []]
    (each [_ run (pairs state.jobs)] (table.insert out run))
    (table.sort out (fn [a b] (< (or a.seq 0) (or b.seq 0))))
    out))

(fn M.detach-job! [id]
  (tset state.jobs id nil))

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
  (let [run (. state.active id)]
    (when run
      (when (= run.event-errors nil) (set run.event-errors []))
      (table.insert run.event-errors err)
      (trim-list! run.event-errors MAX-EVENT-ERRORS))
    run))

(fn M.set-event-offset! [id offset]
  (let [run (. state.active id)]
    (when run (set run.event-offset offset))
    run))

(fn M.request-steer! [id note ?source]
  (let [run (. state.active id)
        full-note (text.trim (tostring (or note "")))]
    (when run
      (let [rec {:note full-note
                 :summary (task-summary full-note)
                 :source (or ?source :user)
                 :requested-at (os.time)}]
        (table.insert run.steering-notes rec)
        (table.insert run.pending-steering rec)
        (trim-list! run.steering-notes MAX-STEERING-NOTES)
        (M.append-event! id {:type :steering :summary rec.summary :source rec.source})))
    run))

(fn M.take-steering! [id]
  (let [run (. state.active id)]
    (when (and run (> (length (or run.pending-steering [])) 0))
      (table.remove run.pending-steering 1))))

(fn M.note-restart! [id]
  (let [run (. state.active id)]
    (when run
      (set run.restart-count (+ (or run.restart-count 0) 1)))
    run))

(fn M.active-runs []
  (let [out []]
    (each [_ run (pairs state.active)]
      (table.insert out (copy-run run)))
    (table.sort out (fn [a b] (< (or a.seq 0) (or b.seq 0))))
    out))

(fn M.runs []
  (let [out []]
    (each [_ run (ipairs state.runs)]
      (table.insert out (copy-run run)))
    out))

(fn M.snapshot []
  {:active-count (active-count)
   :active-runs (M.active-runs)
   :next-id state.next-id
   :runs (M.runs)})

(fn M.reconcile-background! []
  "Finish background runs whose process job is no longer attached. Blocking
   runs legitimately have no job entry and are left alone."
  (let [stale []]
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
  (if (. state.active id)
      (values nil "run is active")
      (let []
        (var removed nil)
        (var found nil)
        (each [i run (ipairs state.runs)]
          (when (and (not found) (= run.id id))
            (set found i)
            (set removed run)))
        (when found (table.remove state.runs found))
        (values removed (and (not removed) "run not found")))))

(fn M.clear! []
  "Clear run records after callers have reaped active jobs. Preserve the
   process-lifetime id sequence so a stale run id cannot name a future child."
  (set state.runs [])
  (set state.active {})
  (set state.jobs {})
  nil)

(fn M.reset! []
  "Test/startup reset, including the process-lifetime id sequence."
  (set state.next-id 0)
  (M.clear!))

(set M._state state)

M
