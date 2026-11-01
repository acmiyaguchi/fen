;; The session holder and its mailbox (spec/core/tasks/proofs/holder,
;; `holderAbstract`).
;;
;; holder     who has the session: :none | :turn (with number n) | :exclusive
;; steer      a line for the running turn
;; follow-up  a line for a natural stop or a later turn
;; seq        the mailbox's own admission number (FIFO order and identity)
;; tag        the caller's opaque id for a line: carried back, never used for
;;            order or lookup
;;
;; `step` is pure: (step machine input) -> (machine' outputs). It never
;; mutates its argument and never touches the bus, so tests and the Quint
;; conformance replay drive it directly. `dispatch!` is the thin shell that
;; advances `fen.core.tasks.state.machine` and turns event-shaped outputs into
;; bus events. The public verbs below are thin wrappers over `dispatch!`.
;;
;; `spawn-holder` is the only way to hold
;; the session; `next-start!` is the only way a turn starts from queued input.

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
  {:kind :none
   :n 0
   :hid 0
   :steer []
   :follow-up []
   :start? false
   :first-up nil
   :cancel? false
   :modes {:steering :one-at-a-time :follow-up :one-at-a-time}
   :next-seq 1})

(fn migrate [m]
  "A machine left by the pre-holder mailbox (a /reload into this code): keep
   its turn number and follow-ups. /reload is idle-only, so nothing held it."
  (if (not= nil m.kind)
      m
      (let [out (initial-machine)]
        (set out.n (or m.turn 0))
        (each [_ item (ipairs (or m.follow-ups []))]
          (table.insert out.follow-up {:seq out.next-seq :text item.text})
          (set out.next-seq (+ out.next-seq 1)))
        (set out.start?
             (and (not (not m.idle-start?)) (> (length out.follow-up) 0)))
        (when out.start?
          (set out.first-up (. out.follow-up 1 :seq)))
        (when m.modes
          (set out.modes
               {:steering (or m.modes.steering :one-at-a-time)
                :follow-up (or m.modes.follow-up :one-at-a-time)}))
        out)))

(fn copy-machine [m]
  ;; Items are immutable once created, so a shallow list copy suffices.
  (let [m (migrate m)]
    {:kind m.kind
     :n m.n
     :hid m.hid
     :steer (icollect [_ item (ipairs m.steer)] item)
     :follow-up (icollect [_ item (ipairs m.follow-up)] item)
     :start? m.start?
     :first-up m.first-up
     :cancel? m.cancel?
     :modes {:steering m.modes.steering :follow-up m.modes.follow-up}
     :next-seq m.next-seq}))

(fn live []
  (let [m (migrate state.machine)]
    (set state.machine m)
    m))

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

(fn busy? [m] (not= m.kind :none))

(fn start-pending? [m]
  (and m.start? (> (length m.follow-up) 0)))

(local STEPS {})

;; (spawn-holder kind f), acquire half. Never replaces a holder; a pending turn
;; start has priority over an exclusive holder.
(fn STEPS.acquire [m input outs]
  (let [kind input.kind]
    (if (not (or (= kind :turn) (= kind :exclusive)))
        (table.insert outs
                      (reject (.. "unknown holder kind: " (tostring kind))))
        (busy? m)
        (table.insert outs {:type :hold-refused
                            : kind
                            :reason (.. "session is busy ("
                                        (if (= m.kind :turn)
                                            (.. "turn " (tostring m.n))
                                            (tostring m.kind))
                                        ")")})
        ;; Turns start from queued input only through :next-start
        ;; (startTurn); a plain acquire never jumps a requested start.
        (start-pending? m)
        (table.insert outs
                      {:type :hold-refused
                       : kind
                       :reason "a queued turn is about to start; try again when it finishes"})
        (do
          (set m.kind kind)
          (set m.hid (+ m.hid 1))
          (set m.cancel? false)
          (when (= kind :turn)
            (set m.n (+ m.n 1)))
          (table.insert outs {:type :held : kind :n m.n :hid m.hid})
          (table.insert outs (counts m))))))

;; Release: the holder's body exited (return, error, cancel) or its coroutine
;; was dropped. Fenced by holder id, so a stale release is a no-op. The turn's
;; unread steer lines are handed back, attributed to that turn.
(fn STEPS.release [m input outs]
  (when (and (busy? m) (or (= input.hid nil) (= input.hid m.hid)))
    (let [kind m.kind
          leftover m.steer]
      (set m.kind :none)
      (set m.steer [])
      (set m.cancel? false)
      (table.insert outs {:type :released : kind :turn m.n :items leftover})
      (table.insert outs (counts m)))))

(fn admit! [m outs item queue start?]
  (if (= queue :steering)
      (table.insert m.steer item)
      (table.insert m.follow-up item))
  (when start?
    (set m.start? true)
    ;; The line whose idle offer raised the request starts first.
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
;; > 0: steer only that turn.
(fn STEPS.offer [m input outs]
  (if (not (valid-text? input.text))
      (table.insert outs (reject "cannot queue an empty message"))
      (let [item {:seq m.next-seq :tag input.tag :text input.text}
            t input.turn]
        (set m.next-seq (+ m.next-seq 1))
        (if input.follow-up?
            (admit! m outs item :follow-up false)
            (and t (> t 0))
            (if (and (= m.kind :turn) (= t m.n))
                (admit! m outs item :steering false)
                (refuse! m outs item
                         (.. "turn " (tostring t) " is not running"
                             (if (= m.kind :turn)
                                 (.. " (turn " (tostring m.n) " is)")
                                 ""))))
            (= t 0)
            (if (busy? m)
                (refuse! m outs item "session is busy")
                (admit! m outs item :follow-up true))
            (= m.kind :turn)
            (admit! m outs item :steering false)
            (= m.kind :exclusive)
            (admit! m outs item :follow-up false)
            (admit! m outs item :follow-up true)))))

(fn STEPS.take [m input outs]
  (let [queue (canonical-queue input.queue)
        taken (if (not= m.kind :turn) [] (= queue :steering)
                  (take-by-mode! m.steer m.modes.steering)
                  ;; Steering wins: follow-ups only once steer lines are drained.
                  (and (= queue :follow-up) (= (length m.steer) 0))
                  (take-by-mode! m.follow-up m.modes.follow-up) [])]
    (table.insert outs {:type :taken : queue :turn m.n :items taken})
    (when (> (length taken) 0) (table.insert outs (counts m)))))

;; next-start! (startTurn): the single start path, one step. Pops the line
;; whose idle offer asked for the start (else the oldest follow-up) AND takes
;; the :turn holder for turn n+1, so nothing runs between the pick and the
;; hold. The driver then runs the turn body under that holder id.
(fn start! [m outs]
  (when (and (not (busy? m)) (start-pending? m))
    (var idx 1)
    (each [i item (ipairs m.follow-up)]
      (when (= item.seq m.first-up) (set idx i)))
    (let [item (table.remove m.follow-up idx)]
      (set m.start? false)
      (set m.first-up nil)
      (set m.kind :turn)
      (set m.n (+ m.n 1))
      (set m.hid (+ m.hid 1))
      (set m.cancel? false)
      (table.insert outs {:type :started : item :turn m.n :hid m.hid})
      (table.insert outs (counts m))
      item)))

(fn STEPS.next-start [m _input outs]
  (start! m outs))

;; Deprecated (idle-tick! shim for a pre-holder runtime): pop the start line
;; without holding; that runtime then submits it as a new local offer.
(fn STEPS.legacy-pop-start [m _input outs]
  (when (and (not (busy? m)) (start-pending? m))
    (var idx 1)
    (each [i item (ipairs m.follow-up)]
      (when (= item.seq m.first-up) (set idx i)))
    (let [item (table.remove m.follow-up idx)]
      (set m.start? false)
      (set m.first-up nil)
      (table.insert outs {:type :popped : item})
      (table.insert outs (counts m)))))

;; offer! then next-start! in one step (an idle submit). The offer the start
;; consumes is marked so no :queued event is shown for it.
(fn STEPS.offer-start [m input outs]
  (STEPS.offer m input outs)
  (let [admitted (accumulate [a nil _ o (ipairs outs)]
                   (if (= o.type :admitted) o a))
        item (start! m outs)]
    (when (and admitted item (= item.seq admitted.seq))
      (set admitted.consumed? true))))

;; cancel! hid (cancelHolder): arms only the holder that is still holder hid,
;; turn or exclusive; release clears it, so a stale keypress is a no-op.
(fn STEPS.cancel [m input outs]
  (let [ok? (and (busy? m) (= input.hid m.hid))]
    (when ok? (set m.cancel? true))
    (table.insert outs {:type :cancel :accepted? ok? :hid m.hid})))

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

;; @doc fen.core.tasks.step
;; kind: function
;; signature: (step machine input) -> machine' [output]
;; summary: Pure step of the session holder and mailbox. Inputs: :acquire, :release, :offer, :take, :next-start, :cancel, :clear, :set-mode. Outputs: :held, :hold-refused, :released, :admitted, :refused, :rejected, :taken, :started, :cancel, :cleared, :mode, :counts.
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
                              :tags (tags out.items)}))))

;; @doc fen.core.tasks.dispatch!
;; kind: function
;; signature: (dispatch! input) -> [output]
;; summary: Advance the live machine by one step and emit its event outputs (:counts as :set-status-info, :admitted as :queued, released steer lines as :steering-returned with :turn :texts :tags); returns every output.
;; tags: tasks steering
(fn M.dispatch! [input]
  (let [(m outs) (M.step (live) input)]
    (set state.machine m)
    ;; One status update per step: the last :counts is the settled state.
    (var last-counts nil)
    (each [_ out (ipairs outs)]
      (when (= out.type :counts) (set last-counts out)))
    (each [_ out (ipairs outs)]
      (when (or (not= out.type :counts) (= out last-counts))
        (emit-output! out)))
    outs))

(fn find-output [outs typ]
  (var found nil)
  (each [_ out (ipairs outs)]
    (when (and (not found) (= out.type typ)) (set found out)))
  found)

;; @doc fen.core.tasks.holder
;; kind: function
;; signature: (holder) -> {:kind :none|:turn|:exclusive :n n :hid n :cancel? bool}
;; summary: Who holds the session now, the current (or last) turn number, the holder id release! fences on, and whether cancel! armed it.
;; tags: tasks turn
(fn M.holder []
  (let [m (live)]
    {:kind m.kind :n m.n :hid m.hid :cancel? m.cancel?}))

;; @doc fen.core.tasks.release!
;; kind: function
;; signature: (release! hid) -> [text]|nil
;; summary: Release holder hid (fenced: a no-op unless hid still holds). spawn-holder bodies call it on every exit; code that drops a held coroutine without resuming it to completion calls it too. Returns the handed-back steer lines, also emitted as :steering-returned.
;; tags: tasks turn
(fn M.release! [hid]
  (let [out (find-output (M.dispatch! {:type :release : hid}) :released)]
    (when out (texts out.items))))

(fn acquire! [kind]
  (let [outs (M.dispatch! {:type :acquire : kind})
        held (find-output outs :held)]
    (if held
        (values held.hid held.n)
        (values nil (or (?. (find-output outs :hold-refused) :reason)
                        (?. (find-output outs :rejected) :reason)
                        "cannot hold the session")))))

(fn keep-error [e]
  ;; Error objects (cancel markers) pass through; strings get the traceback.
  (if (= (type e) :string) (debug.traceback e 2) e))

(fn run-held [hid f ...]
  (let [result (table.pack (xpcall f keep-error ...))]
    ;; Resolved through the module table: the body may span a /reload.
    ((. (require :fen.core.tasks) :release!) hid)
    (if (. result 1)
        (table.unpack result 2 result.n)
        (error (. result 2) 0))))

;; @doc fen.core.tasks.spawn-holder
;; kind: function
;; signature: (spawn-holder kind f) -> co hid n|nil reason
;; summary: The only acquire: hold the session as :turn or :exclusive now (never replacing a holder; refused while a queued turn start is pending) and return a coroutine whose body runs f and releases on every exit (return, error, cancel); f's errors propagate after release. A caller that drops the coroutine without resuming it to completion must call (release! hid).
;; tags: tasks turn
(fn M.spawn-holder [kind f]
  (let [(hid n-or-why) (acquire! kind)]
    (if hid
        (values (coroutines.create (fn [...] (run-held hid f ...))) hid
                n-or-why)
        (values nil n-or-why))))

;; @doc fen.core.tasks.offer!
;; kind: function
;; signature: (offer! text ?opts) -> {:ok true :queue kind :seq n :tag tag :start-pending? bool}|{:ok false :refused? bool :error msg :tag tag :turn n}
;; summary: Queue a line; never starts a turn. opts: :tag (opaque, carried back), :follow-up? (always a follow-up), :turn (n: steer only turn n; 0: start only if idle). Without :turn: steer a running turn, follow up an exclusive holder, or follow up and request an idle start.
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

;; @doc fen.core.tasks.next-start!
;; kind: function
;; signature: (next-start!) -> {:seq :tag :text} hid n|nil
;; summary: The single start step: when idle with a start requested, pop the line that asked for it (else the oldest follow-up) and take the :turn holder for turn n in the same step. The caller owns holder hid and must run a body under it (spawn-next does) or release! it.
;; tags: tasks steering runtime
(fn M.next-start! []
  (let [out (find-output (M.dispatch! {:type :next-start}) :started)]
    (when out (values out.item out.hid out.turn))))

(fn held-coroutine [hid f]
  (coroutines.create (fn [...] (run-held hid f ...))))

;; @doc fen.core.tasks.spawn-next
;; kind: function
;; signature: (spawn-next make-body) -> co item n hid|nil
;; summary: next-start! plus the turn coroutine: (make-body item n hid) returns the body, run under the turn holder and released on every exit.
;; tags: tasks steering runtime
(fn M.spawn-next [make-body]
  (let [(item hid n) (M.next-start!)]
    (when item
      (values (held-coroutine hid (make-body item n hid)) item n hid))))

;; @doc fen.core.tasks.offer-start!
;; kind: function
;; signature: (offer-start! text ?opts make-body) -> {:ok true :started? bool :co co :item item :turn n :hid hid}|{:ok false :error msg}
;; summary: An idle submit in one step: offer text (local, or opts.turn 0) and, if that raises the start request, start the turn at once. The line that asked first starts; a line it did not start stays queued (and is shown as queued).
;; tags: tasks steering runtime
(fn M.offer-start! [text ?opts make-body]
  (let [opts (or ?opts {})
        outs (M.dispatch! {:type :offer-start
                           : text
                           :tag opts.tag
                           :turn opts.turn})
        started (find-output outs :started)
        admitted (find-output outs :admitted)]
    (if started
        {:ok true
         :started? true
         :item started.item
         :turn started.turn
         :hid started.hid
         :co (held-coroutine started.hid
                             (make-body started.item started.turn started.hid))}
        admitted
        {:ok true :started? false :queue admitted.queue :seq admitted.seq}
        {:ok false
         :error (or (?. (find-output outs :refused) :reason)
                    (?. (find-output outs :rejected) :reason) "rejected")})))

;; @doc fen.core.tasks.start-pending?
;; kind: function
;; signature: (start-pending?) -> bool
;; summary: Whether an idle offer asked for a turn start that next-start! has not taken yet.
;; tags: tasks steering runtime
(fn M.start-pending? []
  (start-pending? (live)))

;; Deprecated shims for closures captured by the pre-holder runtime (a872c57)
;; that survive a /reload into this code (modules reload in place).
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

;; @doc fen.core.tasks.cancel!
;; kind: function
;; signature: (cancel! hid) -> ok?
;; summary: Arm cancellation of holder hid (a turn or an exclusive job); fenced, so it does nothing unless hid still holds the session. Cancel entry points read (holder).hid when the request is made.
;; tags: tasks turn
(fn M.cancel! [hid]
  (?. (find-output (M.dispatch! {:type :cancel : hid}) :cancel) :accepted?))

;; @doc fen.core.tasks.cancel-current!
;; kind: function
;; signature: (cancel-current!) -> ok?
;; summary: Ctrl-C and other cancel controls: cancel! the holder that holds right now.
;; tags: tasks turn
(fn M.cancel-current! []
  (M.cancel! (. (live) :hid)))

;; @doc fen.core.tasks.cancel-requested?
;; kind: function
;; signature: (cancel-requested? hid ?state) -> bool
;; summary: Whether cancel! armed holder hid and it still holds. ?state maps a pre-holder closure's state.cancel-requested? flag (a session reloaded from older code) onto cancel! of hid.
;; tags: tasks turn
(fn M.cancel-requested? [hid ?state]
  (when (and ?state ?state.cancel-requested?)
    (set ?state.cancel-requested? nil)
    (M.cancel! hid))
  (let [m (live)]
    (and (not= m.kind :none) (= m.hid hid) m.cancel?)))

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
;; signature: (snapshot) -> {:holder kind :turn n :running? bool :steering [text] :follow-up [text] :steering-mode mode :follow-up-mode mode}
;; summary: Copied queue texts, modes, holder, and turn for UI rendering such as the /queue panel.
;; tags: tasks steering introspect
(fn M.snapshot []
  (let [m (live)]
    {:holder m.kind
     :turn m.n
     :running? (= m.kind :turn)
     :steering (texts m.steer)
     :follow-up (texts m.follow-up)
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
    (tset (live) :start? false)
    (tset (live) :first-up nil)))

;; @doc fen.core.tasks.reset!
;; kind: function
;; signature: (reset!) -> nil
;; summary: Restore the initial machine; for tests.
;; tags: tasks testing
(fn M.reset! []
  (set state.machine (initial-machine))
  (set state.attached? false))

(set M.initial-machine initial-machine)

M
