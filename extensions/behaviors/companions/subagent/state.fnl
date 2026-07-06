;; Persistent subagent run state.
;;
;; This module is intentionally kept out of the subagent manifest's
;; reload-modules list so /reload can replace behavior while preserving active
;; and recent run records.

(local text (require :fen.util.text))

(local M {})
(local MAX-RUNS 20)
(local MAX-EVENTS 50)
(local MAX-EVENT-ERRORS 20)
(local MAX-STEERING-NOTES 20)
(local SUMMARY-BYTES 96)

(local state {:next-id 0
              :runs []
              :active {}})

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
  (let [out (copy run)]
    (set out.events (copy-list run.events))
    (set out.event-errors (copy-list run.event-errors))
    (set out.steering-notes (copy-list run.steering-notes))
    (set out.pending-steering (copy-list run.pending-steering))
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
             :events []
             :event-errors []
             :restart-count 0
             :steering-notes []
             :pending-steering []}]
    (table.insert state.runs run)
    (tset state.active id run)
    (trim-runs!)
    run))

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
      (tset state.active id nil)
      (trim-runs!))
    run))

(fn M.active-count []
  (active-count))

(fn M.append-event! [id ev]
  (let [run (find-run id)]
    (when run
      (set run.event-count (+ (or run.event-count 0) 1))
      (when (= run.events nil) (set run.events []))
      (table.insert run.events ev)
      (trim-list! run.events MAX-EVENTS))
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

(fn M.reset! []
  (set state.next-id 0)
  (set state.runs [])
  (set state.active {})
  nil)

(set M._state state)

M
