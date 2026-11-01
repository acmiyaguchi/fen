;; The session holder, its mailbox, and the one job scheduler
;; (spec/core/tasks/proofs/holder, `holderAbstract`).
;;
;; holder     who has the session: nil | {:kind :turn :n :hid :cancel?}
;;            | {:kind :exclusive :job :hid :cancel?}
;; steer      a line for the running turn
;; follow-up  a line for a natural stop or a later turn
;; seq        the mailbox's own admission number (FIFO order and identity)
;; tag        the caller's opaque id for a line: carried back, never used for
;;            order or lookup
;; job        an exclusive job (/reload, /handoff, compaction) waiting in the
;;            scheduler's queue, or the body of the holder that runs it
;;
;; A closed-loop Mealy machine. `step` is pure: (step machine input) ->
;; (machine' outputs). Outputs are data: notifications (:admitted, :started,
;; :released ...) and effects (:spawn, :forget). `dispatch!` commits the new
;; machine first and then interprets the outputs: it creates and registers
;; each spawned coroutine, emits bus events, and feeds any failure back as an
;; input ({:type :spawn-failed :hid}) whose step releases. So no effect ever
;; runs between two state changes of one operation, and a holder id never
;; leaves this module without its coroutine registered in the job table
;; (`fen.core.tasks.state.jobs`). The body itself is built inside the
;; protected coroutine, so a builder that throws is released like any body
;; error.
;;
;; Starting work has one path, the scheduler step `:next-job`: a pending turn
;; start goes first, else the oldest requested exclusive job.

(local state (require :fen.core.tasks.state))
(local events (require :fen.core.extensions.events))
(local coroutines (require :fen.util.coroutines))

(local M {})

(local MODES {:one-at-a-time true :all true})

(fn canonical-queue [kind]
  (if (= kind :steering) :steering
      (= kind :follow-up) :follow-up
      nil))

(fn initial-machine []
  {:holder nil
   :n 0
   :hid 0
   :steer []
   :follow-up []
   :start? false
   :first-up nil
   :jobs []
   :next-job 1
   :modes {:steering :one-at-a-time :follow-up :one-at-a-time}
   :next-seq 1})

(fn migrate [m]
  "A machine left by older code after a /reload (modules reload in place):
   keep the turn number, follow-ups, and modes. /reload runs idle or as the
   exclusive job itself, so at most that job's holder is carried."
  (if (not= nil m.jobs)
      m
      (let [out (initial-machine)]
        (set out.n (or m.n m.turn 0))
        (set out.hid (or m.hid 0))
        (set out.next-seq (or m.next-seq 1))
        (each [_ item (ipairs (or m.follow-up m.follow-ups []))]
          (table.insert out.follow-up
                        {:seq (or item.seq out.next-seq)
                         :tag item.tag
                         :text item.text})
          (set out.next-seq (math.max out.next-seq (+ (or item.seq 0) 1))))
        (when (= nil m.follow-up)
          (set out.next-seq (+ out.next-seq (length out.follow-up))))
        (when (or m.start? m.idle-start?)
          (when (> (length out.follow-up) 0)
            (set out.start? true)
            (set out.first-up (or m.first-up (. out.follow-up 1 :seq)))))
        (when (= m.kind :exclusive)
          (set out.holder {:kind :exclusive :job 0 :hid m.hid :cancel? false}))
        (when m.modes
          (set out.modes
               {:steering (or m.modes.steering :one-at-a-time)
                :follow-up (or m.modes.follow-up :one-at-a-time)}))
        out)))

(fn copy-holder [h]
  (when h
    (case h.kind
      :turn {:kind :turn :n h.n :hid h.hid :cancel? h.cancel?}
      :exclusive {:kind :exclusive :job h.job :hid h.hid :cancel? h.cancel?})))

(fn copy-machine [m]
  ;; Items and job entries are immutable once created: shallow list copies.
  (let [m (migrate m)]
    {:holder (copy-holder m.holder)
     :n m.n
     :hid m.hid
     :steer (icollect [_ item (ipairs m.steer)] item)
     :follow-up (icollect [_ item (ipairs m.follow-up)] item)
     :start? m.start?
     :first-up m.first-up
     :jobs (icollect [_ job (ipairs m.jobs)] job)
     :next-job m.next-job
     :modes {:steering m.modes.steering :follow-up m.modes.follow-up}
     :next-seq m.next-seq}))

(fn live []
  ;; A state table kept from older code across /reload has no job table yet.
  (when (= nil state.jobs) (set state.jobs {}))
  (let [m (migrate state.machine)]
    (set state.machine m)
    m))

(fn kind-of [m]
  (if m.holder m.holder.kind :none))

;; @doc fen.core.tasks.info
;; kind: function
;; signature: (info ?machine) -> {:steering-queued n :follow-up-queued n :steering-mode mode :follow-up-mode mode}
;; summary: Queue depths and drain modes in the status-line field names, for the given machine or the live one.
;; tags: tasks steering status
(fn M.info [?machine]
  (let [m (migrate (or ?machine state.machine))]
    {:steering-queued (length m.steer)
     :follow-up-queued (length m.follow-up)
     :steering-mode m.modes.steering
     :follow-up-mode m.modes.follow-up}))

(fn counts [m]
  {:type :counts :info (M.info m)})

(fn reject [reason]
  {:type :rejected : reason})

(fn texts [items]
  (icollect [_ item (ipairs items)] item.text))

(fn tags [items]
  (icollect [_ item (ipairs items)] item.tag))

(fn take-by-mode! [items mode]
  "Remove the head item, or every item for mode :all; return them in order."
  (let [out []]
    (while (and (> (length items) 0) (or (= mode :all) (= (length out) 0)))
      (table.insert out (table.remove items 1)))
    out))

(fn valid-text? [text]
  (and (= (type text) :string) (not= text "")))

(fn start-pending? [m]
  (and m.start? (> (length m.follow-up) 0)))

(fn pop-start-line! [m]
  "Remove the line whose offer asked for the start (else the oldest
   follow-up) and clear the request."
  (var idx 1)
  (each [i item (ipairs m.follow-up)]
    (when (= item.seq m.first-up) (set idx i)))
  (set m.start? false)
  (set m.first-up nil)
  (table.remove m.follow-up idx))

(local STEPS {})

;; ---- scheduler ----

(fn start-turn! [m input outs]
  "startTurn: the start line opens turn n+1 under a fresh holder id."
  (let [item (pop-start-line! m)]
    (set m.n (+ m.n 1))
    (set m.hid (+ m.hid 1))
    (set m.holder {:kind :turn :n m.n :hid m.hid :cancel? false})
    (table.insert outs {:type :started : item :turn m.n :hid m.hid})
    (table.insert outs {:type :spawn
                        :kind :turn
                        :hid m.hid
                        : item
                        :n m.n
                        :make-turn input.make-turn
                        :on-spawn input.on-turn})
    (table.insert outs (counts m))
    item))

(fn start-exclusive! [m outs]
  "startExclusive: the oldest requested job takes the session."
  (let [job (table.remove m.jobs 1)]
    (set m.hid (+ m.hid 1))
    (set m.holder {:kind :exclusive :job job.id :hid m.hid :cancel? false})
    (table.insert outs {:type :job-started :job job.id :hid m.hid})
    (table.insert outs
                  {:type :spawn
                   :kind :exclusive
                   :hid m.hid
                   : job
                   :on-spawn (?. job :spec :on-spawn)})
    job))

(fn schedule! [m input outs]
  "next-job!: when idle, a pending turn start goes first, else the oldest
   requested exclusive job."
  (when (= m.holder nil)
    (if (start-pending? m) (start-turn! m input outs)
        (> (length m.jobs) 0) (start-exclusive! m outs))))

(fn STEPS.next-job [m input outs]
  (schedule! m input outs))

;; request-job!: an exclusive job asks the scheduler; it never starts itself
;; past a pending turn. A request with the key of one already waiting updates
;; that one instead.
(fn STEPS.request-job [m input outs]
  (let [spec (or input.spec {})
        at (when spec.key
             (accumulate [found nil i job (ipairs m.jobs)]
               (or found (when (= job.spec.key spec.key) i))))]
    (if at
        ;; Replace the waiting entry (entries are shared with the old machine).
        (let [old (. m.jobs at)
              merged (collect [k v (pairs old.spec)] k v)]
          (set merged.reason spec.reason)
          (tset m.jobs at {:id old.id :spec merged})
          (table.insert outs {:type :requested :job old.id :merged? true}))
        (let [job {:id m.next-job : spec}]
          (set m.next-job (+ m.next-job 1))
          (table.insert m.jobs job)
          (table.insert outs {:type :requested :job job.id})))
    (when (and input.start-now? (not (start-pending? m)))
      (schedule! m {} outs))))

;; ---- holder exit ----

(fn release! [m hid outs reason]
  "The holder's body exited (return, error, cancel), its coroutine was
   dropped, or it could not be spawned. Fenced by holder id: nil or a stale
   id is a no-op. A turn's unread steer lines are handed back."
  (let [h m.holder]
    (when (and h (not= hid nil) (= hid h.hid))
      (let [leftover m.steer
            turn (when (= h.kind :turn) h.n)]
        (set m.holder nil)
        (set m.steer [])
        (table.insert outs {:type :released
                            :kind h.kind
                            : turn
                            : hid
                            : reason
                            :items leftover})
        (table.insert outs {:type :forget : hid})
        (table.insert outs (counts m))))))

(fn STEPS.release [m input outs]
  (release! m input.hid outs :exit))

(fn STEPS.spawn-failed [m input outs]
  (release! m input.hid outs :spawn-failed)
  (table.insert outs {:type :spawn-error :hid input.hid :error input.error}))

;; ---- mailbox ----

(fn admit! [m outs item queue start?]
  (if (= queue :steering)
      (table.insert m.steer item)
      (table.insert m.follow-up item))
  (when start?
    (set m.start? true)
    ;; The line whose offer raised the request starts first.
    (when (= m.first-up nil) (set m.first-up item.seq)))
  (table.insert outs {:type :admitted
                      :seq item.seq
                      :tag item.tag
                      :text item.text
                      : queue
                      :start? start?})
  (table.insert outs (counts m)))

(fn refuse! [m outs item reason]
  (table.insert outs {:type :refused
                      :seq item.seq
                      :tag item.tag
                      :text item.text
                      :turn m.n
                      : reason}))

;; offer! routing. turn nil: local (Enter, extensions); 0: start only if idle;
;; > 0: steer only that turn. A local line behind an exclusive job asks for
;; the turn that follows it.
(fn STEPS.offer [m input outs]
  (if (not (valid-text? input.text))
      (table.insert outs (reject "cannot queue an empty message"))
      ;; :make-turn rides on the line (opaque, like :tag): the body of the
      ;; turn this line starts, whenever the scheduler starts it.
      (let [item {:seq m.next-seq
                  :tag input.tag
                  :text input.text
                  :make-turn input.line-turn}
            t input.turn
            h m.holder]
        (set m.next-seq (+ m.next-seq 1))
        (if input.follow-up?
            (admit! m outs item :follow-up false)
            (and t (> t 0))
            (if (and h (= h.kind :turn) (= t h.n))
                (admit! m outs item :steering false)
                (refuse! m outs item
                         (.. "turn " (tostring t) " is not running"
                             (if (and h (= h.kind :turn))
                                 (.. " (turn " (tostring h.n) " is)")
                                 ""))))
            (= t 0)
            (if h
                (refuse! m outs item "session is busy")
                (admit! m outs item :follow-up true))
            (case (kind-of m)
              :turn (admit! m outs item :steering false)
              :exclusive (admit! m outs item :follow-up true)
              :none (admit! m outs item :follow-up true))))))

;; offer! then the turn start it raises, in one step (an idle submit). The
;; offer the start consumes is marked so no :queued event is shown for it.
(fn STEPS.offer-start [m input outs]
  (STEPS.offer m input outs)
  (let [admitted (accumulate [a nil _ o (ipairs outs)]
                   (if (= o.type :admitted) o a))
        item (when (and (= m.holder nil) (start-pending? m))
               (start-turn! m input outs))]
    (when (and admitted item (= item.seq admitted.seq))
      (set admitted.consumed? true))))

;; Deprecated shims (pre-holder runtimes after /reload): pop the start line
;; without holding; that runtime then submits it as a new local offer.
(fn STEPS.legacy-pop-start [m _input outs]
  (when (and (= m.holder nil) (start-pending? m))
    (table.insert outs {:type :popped :item (pop-start-line! m)})
    (table.insert outs (counts m))))

(fn STEPS.take [m input outs]
  (let [queue (canonical-queue input.queue)
        turn? (= (kind-of m) :turn)
        taken (if (not turn?) [] (= queue :steering)
                  (take-by-mode! m.steer m.modes.steering)
                  ;; Steering wins: follow-ups only once steer lines are drained.
                  (and (= queue :follow-up) (= (length m.steer) 0))
                  (take-by-mode! m.follow-up m.modes.follow-up) [])]
    (table.insert outs {:type :taken : queue :turn m.n :items taken})
    (when (> (length taken) 0) (table.insert outs (counts m)))))

;; cancel! hid (cancelHolder): arms only the holder that is still holder hid,
;; turn or exclusive; release clears it, so a stale keypress is a no-op.
(fn STEPS.cancel [m input outs]
  (let [h m.holder
        ok? (and h (not= input.hid nil) (= input.hid h.hid))]
    (when ok? (set h.cancel? true))
    (table.insert outs {:type :cancel :accepted? (not (not ok?)) :hid m.hid})))

(fn STEPS.clear [m input outs]
  (let [kind (canonical-queue input.queue)
        dropped []]
    (when (or (= kind nil) (= kind :steering))
      (each [_ item (ipairs m.steer)] (table.insert dropped item))
      (set m.steer []))
    (when (or (= kind nil) (= kind :follow-up))
      (each [_ item (ipairs m.follow-up)] (table.insert dropped item))
      (set m.follow-up [])
      (set m.start? false)
      (set m.first-up nil))
    (table.insert outs {:type :cleared :turn m.n :items dropped})
    (table.insert outs (counts m))))

(fn STEPS.set-mode [m input outs]
  (let [kind (canonical-queue input.queue)]
    (if (and kind (. MODES input.mode))
        (do
          (tset m.modes kind input.mode)
          (table.insert outs {:type :mode :accepted? true})
          (table.insert outs (counts m)))
        (table.insert outs (reject "unknown queue or mode")))))

(fn STEPS.detach [m _input outs]
  (set m.start? false)
  (set m.first-up nil)
  (table.insert outs (counts m)))

;; @doc fen.core.tasks.step
;; kind: function
;; signature: (step machine input) -> machine' [output]
;; summary: Pure step. Inputs: :offer, :offer-start, :next-job, :request-job, :release, :spawn-failed, :take, :cancel, :clear, :set-mode, :detach, :legacy-pop-start. Outputs: notifications (:admitted, :refused, :rejected, :started, :job-started, :requested, :released, :taken, :cancel, :cleared, :mode, :popped, :counts, :spawn-error) and effects (:spawn, :forget) that dispatch! interprets.
;; tags: tasks steering pure
(fn M.step [machine input]
  (let [m (copy-machine machine)
        outs []
        f (. STEPS (?. input :type))]
    (if f
        (f m input outs)
        (table.insert outs
                      (reject (.. "unknown input: " (tostring (?. input :type))))))
    (values m outs)))

;; ---- interpreter ----

(fn keep-error [e]
  ;; Error objects (cancel markers) pass through; strings get the traceback.
  (if (= (type e) :string) (debug.traceback e 2) e))

(fn run-held [hid build]
  "The protected body of holder hid: build the body here, inside the
   coroutine, run it, and release on every exit."
  (let [result (table.pack (xpcall #((build)) keep-error))]
    ;; Resolved through the module table: the body may span a /reload.
    ((. (require :fen.core.tasks) :release!) hid)
    (if (. result 1)
        (table.unpack result 2 result.n)
        (error (. result 2) 0))))

(fn builder [out]
  (case out.kind
    :turn (let [make-turn (or (?. out.item :make-turn) out.make-turn)
                item out.item
                n out.n
                hid out.hid]
            (fn []
              (if make-turn
                  (make-turn item n hid)
                  (error "turn started without a body builder"))))
    :exclusive (let [run (?. out.job :spec :run)
                     hid out.hid]
                 (fn []
                   (fn [] (when run (run hid)))))))

(fn spawn! [out failures]
  "Create, register, and adopt the coroutine for a :spawn effect. Any
   failure is returned as a :spawn-failed input."
  (let [(ok? err) (pcall (fn []
                           (let [build (builder out)
                                 co (coroutines.create #(run-held out.hid build))]
                             (tset state.jobs out.hid
                                   {: co
                                    :hid out.hid
                                    :kind out.kind
                                    :item out.item
                                    :n out.n
                                    :job out.job})
                             (when out.on-spawn
                               (out.on-spawn co out.hid out.n out.item)))))]
    (when (not ok?)
      (tset state.jobs out.hid nil)
      (table.insert failures
                    {:type :spawn-failed :hid out.hid :error (tostring err)}))))

(fn emit-output! [out]
  (case out.type
    :counts (events.emit {:type :set-status-info :info out.info})
    :admitted (when (not out.consumed?)
                (events.emit {:type :queued
                              :queue out.queue
                              :text out.text
                              :tag out.tag}))
    :started (events.emit {:type :turn-line-started
                           :turn out.turn
                           :text out.item.text
                           :tag out.item.tag})
    :released (when (> (length out.items) 0)
                (events.emit {:type :steering-returned
                              :turn out.turn
                              :texts (texts out.items)
                              :tags (tags out.items)}))
    :spawn-error (events.emit {:type :error
                               :error (.. "could not start session work: "
                                          (tostring out.error))})))

;; @doc fen.core.tasks.dispatch!
;; kind: function
;; signature: (dispatch! input) -> [output]
;; summary: Advance the live machine by one step, commit it, then interpret the outputs: spawn and register coroutines (failures fed back as :spawn-failed inputs), forget released jobs, and emit bus events (:counts as one :set-status-info, :admitted as :queued unless consumed by its start, :started as :turn-line-started, released steer lines as :steering-returned). Returns every output, including those of fed-back inputs.
;; tags: tasks steering
(fn M.dispatch! [input]
  (let [all []
        pending [input]]
    (while (> (length pending) 0)
      (let [(m outs) (M.step (live) (table.remove pending 1))
            failures []]
        (set state.machine m)
        (each [_ out (ipairs outs)]
          (case out.type
            :spawn (spawn! out failures)
            :forget (tset state.jobs out.hid nil)))
        ;; One status update per step: the last :counts is the settled state.
        (var last-counts nil)
        (each [_ out (ipairs outs)]
          (when (= out.type :counts) (set last-counts out)))
        (each [_ out (ipairs outs)]
          (when (or (not= out.type :counts) (= out last-counts))
            (emit-output! out))
          (table.insert all out))
        (each [_ f (ipairs failures)] (table.insert pending f))))
    all))

(fn find-output [outs typ]
  (var found nil)
  (each [_ out (ipairs outs)]
    (when (and (not found) (= out.type typ)) (set found out)))
  found)

;; ---- public API ----

;; @doc fen.core.tasks.holder
;; kind: function
;; signature: (holder) -> {:kind :none|:turn|:exclusive :n n :hid n :job id :cancel? bool}
;; summary: Who holds the session now. :n is the current (or last) turn number, :hid the current (or last) holder id; :job is set for an exclusive holder.
;; tags: tasks turn
(fn M.holder []
  (let [m (live)
        h m.holder]
    {:kind (kind-of m)
     :n m.n
     :hid m.hid
     :job (?. h :job)
     :cancel? (= true (?. h :cancel?))}))

;; @doc fen.core.tasks.release!
;; kind: function
;; signature: (release! hid) -> [text]|nil
;; summary: Release holder hid; a no-op for nil or a hid that no longer holds. Held bodies call it on every exit. Returns the handed-back steer lines, also emitted as :steering-returned.
;; tags: tasks turn
(fn M.release! [hid]
  (let [out (find-output (M.dispatch! {:type :release : hid}) :released)]
    (when out (texts out.items))))

(fn job-result [outs]
  (let [s (find-output outs :spawn)
        failed? (find-output outs :spawn-error)]
    (when (and s (not failed?))
      (let [job (. state.jobs s.hid)]
        {:kind s.kind
         :hid s.hid
         :co (?. job :co)
         :item s.item
         :turn s.n
         :job (?. s.job :id)}))))

;; @doc fen.core.tasks.next-job!
;; kind: function
;; signature: (next-job! ?opts) -> {:kind :turn|:exclusive :co co :hid hid :item item :turn n :job id}|nil
;; summary: The scheduler, at the driver's idle tick: start the pending turn if any (opts.make-turn (fn [item n hid]) returns its body, built inside the held coroutine; opts.on-turn (fn [co hid n item]) adopts it), else the oldest requested exclusive job. The coroutine is registered in the job table before anything else runs.
;; tags: tasks steering runtime
(fn M.next-job! [?opts]
  (let [opts (or ?opts {})]
    (job-result (M.dispatch! {:type :next-job
                              :make-turn opts.make-turn
                              :on-turn opts.on-turn}))))

;; @doc fen.core.tasks.request-job!
;; kind: function
;; signature: (request-job! spec) -> {:requested job-id :started? bool :co co :hid hid}
;; summary: Ask the scheduler for an exclusive job. spec: :run (fn [hid]) the body, :on-spawn (fn [co hid]) adopts the coroutine, :key coalesces a still-waiting request, :reason. Starts at once only when idle with no turn start pending; else it waits for next-job!, behind any pending turn.
;; tags: tasks runtime
(fn M.request-job! [spec]
  (let [outs (M.dispatch! {:type :request-job : spec :start-now? true})
        req (find-output outs :requested)
        started (job-result outs)]
    {:requested (?. req :job)
     :started? (not= nil started)
     :co (?. started :co)
     :hid (?. started :hid)}))

;; @doc fen.core.tasks.adopter
;; kind: function
;; signature: (adopter state) -> (fn [co hid])
;; summary: An :on-spawn for request-job! that points a run-state at the job's registered coroutine (state.turn, state.busy?).
;; tags: tasks runtime
(fn M.adopter [run-state]
  (fn [co _hid]
    (set run-state.turn co)
    (set run-state.busy? true)))

;; @doc fen.core.tasks.current-job
;; kind: function
;; signature: (current-job) -> {:co co :hid hid :kind kind :item item :n n :job job}|nil
;; summary: The registered coroutine of the holder that holds now.
;; tags: tasks runtime
(fn M.current-job []
  (let [h (. (live) :holder)]
    (when h (. state.jobs h.hid))))

;; @doc fen.core.tasks.in-exclusive-job?
;; kind: function
;; signature: (in-exclusive-job?) -> bool
;; summary: Whether the caller runs inside the current exclusive job's own coroutine.
;; tags: tasks runtime
(fn M.in-exclusive-job? []
  (let [job (M.current-job)]
    (and (not= job nil) (= job.kind :exclusive) (= job.co (coroutine.running)))))

;; @doc fen.core.tasks.run-exclusive!
;; kind: function
;; signature: (run-exclusive! spec) -> {:inline? true :result value}|request-job! result
;; summary: Run spec.run now when called from inside the current exclusive job's own coroutine (a deferred request dispatching its command), else request-job! it.
;; tags: tasks runtime
(fn M.run-exclusive! [spec]
  (let [job (M.current-job)]
    (if (and job (= job.kind :exclusive) (= job.co (coroutine.running)))
        {:inline? true :result (spec.run job.hid)}
        (M.request-job! spec))))

;; @doc fen.core.tasks.resume-current!
;; kind: function
;; signature: (resume-current! ?co) -> ok? value done?
;; summary: Resume the current job's coroutine (or ?co when it is not a registered job, e.g. a headless state). When a job finishes or errors, its holder is released and its table entry dropped.
;; tags: tasks runtime
(fn M.resume-current! [?co]
  (let [job (M.current-job)
        co (if (and job (or (= ?co nil) (= ?co job.co))) job.co ?co)]
    (if (not co)
        (values true nil true)
        (let [(ok? value) (coroutine.resume co)
              done? (or (not ok?) (= (coroutine.status co) :dead))]
          (when (and done? job (= co job.co))
            (M.release! job.hid)
            (tset state.jobs job.hid nil))
          (values ok? value done?)))))

;; @doc fen.core.tasks.drop-current!
;; kind: function
;; signature: (drop-current! ?co) -> nil
;; summary: Abandon the current job (quit, crash, a presenter that stops resuming it): release its holder and drop its table entry. With ?co, only if the current job is that coroutine, so dropping a finished job never touches a newer one.
;; tags: tasks runtime
(fn M.drop-current! [?co]
  (let [h (. (live) :holder)
        job (when h (. state.jobs h.hid))]
    (when (and h (or (= ?co nil) (= ?co (?. job :co))))
      (M.release! h.hid)
      (tset state.jobs h.hid nil))))

;; @doc fen.core.tasks.offer!
;; kind: function
;; signature: (offer! text ?opts) -> {:ok true :queue kind :seq n :tag tag :start-pending? bool}|{:ok false :refused? bool :error msg :tag tag :turn n}
;; summary: Queue a line; never starts work. opts: :tag (opaque, carried back), :follow-up? (always a follow-up), :turn (n: steer only turn n; 0: start only if idle). Without :turn: steer a running turn; otherwise queue it and request the turn that starts when the session is free.
;; tags: tasks steering
(fn M.offer! [text ?opts]
  (let [opts (or ?opts {})
        outs (M.dispatch! {:type :offer
                           : text
                           :tag opts.tag
                           :turn opts.turn
                           :follow-up? opts.follow-up?})
        ok (find-output outs :admitted)
        no (find-output outs :refused)]
    (if ok
        {:ok true
         :queued true
         :queue ok.queue
         :seq ok.seq
         :tag ok.tag
         :start-pending? (when ok.start?
                           true)}
        no
        {:ok false :refused? true :error no.reason :tag no.tag :turn no.turn}
        {:ok false
         :error (or (?. (find-output outs :rejected) :reason) "rejected")
         :tag opts.tag})))

;; @doc fen.core.tasks.offer-start!
;; kind: function
;; signature: (offer-start! text ?opts) -> {:ok true :started? bool :co co :item item :turn n :hid hid :queue kind :start-pending? bool}|{:ok false :error msg}
;; summary: An idle submit in one step: a local offer and, when idle, the turn start it raises. opts: :tag, :make-turn, :on-turn (as next-job!), :line-turn (this line's own body builder, kept with the line if it waits). The line that asked first starts; a line it did not start stays queued (and is shown as queued); behind an exclusive job the line waits with a start request.
;; tags: tasks steering runtime
(fn M.offer-start! [text ?opts]
  (let [opts (or ?opts {})
        outs (M.dispatch! {:type :offer-start
                           : text
                           :tag opts.tag
                           :line-turn opts.line-turn
                           :make-turn opts.make-turn
                           :on-turn opts.on-turn})
        started (job-result outs)
        admitted (find-output outs :admitted)]
    (if started
        {:ok true
         :started? true
         :co started.co
         :item started.item
         :turn started.turn
         :hid started.hid}
        (and admitted (not (find-output outs :spawn-error)))
        {:ok true
         :started? false
         :queued true
         :queue admitted.queue
         :seq admitted.seq
         :start-pending? (when admitted.start?
                           true)}
        {:ok false
         :error (or (?. (find-output outs :refused) :reason)
                    (?. (find-output outs :rejected) :reason)
                    (?. (find-output outs :spawn-error) :error) "rejected")})))

;; @doc fen.core.tasks.take!
;; kind: function
;; signature: (take! kind) -> [text] [{:seq :tag :text}]
;; summary: Drain lines by mode for injection, only while a turn holds: steering first; follow-ups only once no steer line waits. Returns texts, then the items with their tags.
;; tags: tasks steering agent
(fn M.take! [kind]
  (let [out (find-output (M.dispatch! {:type :take
                                       :queue (canonical-queue kind)})
                         :taken)
        items (or (?. out :items) [])]
    (values (texts items) items)))

;; @doc fen.core.tasks.start-pending?
;; kind: function
;; signature: (start-pending?) -> bool
;; summary: Whether an offer asked for a turn start that the scheduler has not taken yet.
;; tags: tasks steering runtime
(fn M.start-pending? []
  (start-pending? (live)))

;; @doc fen.core.tasks.cancel!
;; kind: function
;; signature: (cancel! hid) -> ok?
;; summary: Arm cancellation of holder hid (a turn or an exclusive job); fenced, so it does nothing unless hid still holds the session.
;; tags: tasks turn
(fn M.cancel! [hid]
  (?. (find-output (M.dispatch! {:type :cancel : hid}) :cancel) :accepted?))

;; @doc fen.core.tasks.cancel-current!
;; kind: function
;; signature: (cancel-current!) -> ok?
;; summary: Ctrl-C and other cancel controls: cancel! the holder that holds right now.
;; tags: tasks turn
(fn M.cancel-current! []
  (let [h (. (live) :holder)]
    (if h (M.cancel! h.hid) false)))

;; @doc fen.core.tasks.cancel-requested?
;; kind: function
;; signature: (cancel-requested? hid ?state) -> bool
;; summary: Whether cancel! armed holder hid and it still holds. ?state maps a pre-holder closure's state.cancel-requested? flag (a session reloaded from older code) onto cancel! of hid.
;; tags: tasks turn
(fn M.cancel-requested? [hid ?state]
  (when (and ?state ?state.cancel-requested?)
    (set ?state.cancel-requested? nil)
    (M.cancel! hid))
  (let [h (. (live) :holder)]
    (and (not= h nil) (= h.hid hid) (= true h.cancel?))))

;; @doc fen.core.tasks.clear!
;; kind: function
;; signature: (clear! ?kind) -> [{:seq :tag :text}]
;; summary: Empty the named queue, or both when kind is nil or :all; clearing follow-ups drops the start request. Returns the cleared items.
;; tags: tasks steering
(fn M.clear! [?kind]
  (or (?. (find-output (M.dispatch! {:type :clear
                                     :queue (canonical-queue ?kind)})
                       :cleared) :items) []))

;; @doc fen.core.tasks.set-mode!
;; kind: function
;; signature: (set-mode! kind mode) -> ok?
;; summary: Set a queue's drain mode to :one-at-a-time or :all; persists across turns, releases, and clears.
;; tags: tasks steering
(fn M.set-mode! [kind mode]
  (= true (?. (find-output (M.dispatch! {:type :set-mode :queue kind : mode})
                           :mode) :accepted?)))

;; @doc fen.core.tasks.snapshot
;; kind: function
;; signature: (snapshot) -> {:holder kind :turn n :running? bool :steering [text] :follow-up [text] :jobs n :steering-mode mode :follow-up-mode mode}
;; summary: Copied queue texts, modes, holder, turn, and the number of waiting exclusive jobs for UI rendering such as the /queue panel.
;; tags: tasks steering introspect
(fn M.snapshot []
  (let [m (live)]
    {:holder (kind-of m)
     :turn m.n
     :running? (= (kind-of m) :turn)
     :steering (texts m.steer)
     :follow-up (texts m.follow-up)
     :jobs (length m.jobs)
     :steering-mode m.modes.steering
     :follow-up-mode m.modes.follow-up}))

;; @doc fen.core.tasks.attach!
;; kind: function
;; signature: (attach! attached?) -> nil
;; summary: Mark whether an interactive runtime drives the machine; detaching drops a pending idle start.
;; tags: tasks runtime
(fn M.attach! [attached?]
  (set state.attached? (not (not attached?)))
  (when (not attached?)
    (M.dispatch! {:type :detach})))

;; @doc fen.core.tasks.reset!
;; kind: function
;; signature: (reset!) -> nil
;; summary: Restore the initial machine and an empty job table; for tests.
;; tags: tasks testing
(fn M.reset! []
  (set state.machine (initial-machine))
  (set state.jobs {})
  (set state.attached? false))

(set M.initial-machine initial-machine)

;; ---- deprecated shims ----
;; Closures captured by older runtimes (a872c57, and the older steering
;; runtime) survive a /reload into this code (modules reload in place). None
;; of them can take a holder: they pop without holding, offer, or no-op.

(var restart-notice-shown? false)

(fn restart-notice! []
  (when (not restart-notice-shown?)
    ;; lint-allow reload/state: one notice per loaded instance is enough; a later /reload may show it once more
    (set restart-notice-shown? true)
    (events.emit {:type :info
                  :text "fen was reloaded across a turn-mailbox change; restart fen to finish the upgrade"})))

(fn M.idle-tick! []
  "Deprecated: the old idle tick. Pops the start line without holding; the
   old runtime submits it, which starts it through offer-start!."
  (?. (find-output (M.dispatch! {:type :legacy-pop-start}) :popped) :item :text))

(fn M.queue! [kind text ?opts]
  "Deprecated: old queue!."
  (let [opts (or ?opts {})
        h (M.holder)]
    (if (= kind :follow-up)
        (if (and opts.start-if-idle? (= h.kind :none))
            (M.offer! text {:turn 0})
            (M.offer! text {:follow-up? true}))
        (= kind :steering)
        (M.offer! text {:turn (or opts.turn (math.max h.n 1))})
        {:ok false :error "unknown queue"})))

(fn M.steer-or-follow-up! [text]
  "Deprecated: old busy-time input; a local offer."
  (M.offer! text))

(fn M.turn-start! []
  "Deprecated and unsafe (a turn with no holder body): no-op plus a notice."
  (restart-notice!)
  (. (M.holder) :n))

(fn M.turn-end! [?n]
  "Deprecated: release turn ?n (default the running one) if it still holds."
  (let [h (M.holder)]
    (when (and (= h.kind :turn) (or (= ?n nil) (= ?n h.n)))
      (M.release! h.hid))))

M
