;; The turn mailbox: a Mealy machine over the main turn and its queued input.
;;
;; `step` is pure: (step machine input) -> (machine' outputs). It never
;; mutates its argument and never touches the bus, so tests and the Quint
;; conformance replay can drive it directly. `dispatch!` is the thin shell
;; that advances `fen.core.tasks.state.machine` and turns event-shaped outputs
;; into bus events.
;;
;; Steering lines are tagged with the turn they were accepted for and are only
;; ever injected into that turn; whatever is left when the turn ends comes back
;; as one `:returned` output (#662, spec/core/tasks requestsAbstract). Follow-ups
;; are untagged and survive turn end.

(local state (require :fen.core.tasks.state))
(local events (require :fen.core.extensions.events))

(local M {})

(local MODES {:one-at-a-time true :all true})

(fn canonical-queue [kind]
  (if (= kind :steering) :steering
      (= kind :follow-up) :follow-up
      nil))

(fn copy-machine [m]
  ;; Queue items are immutable once created, so a shallow list copy suffices.
  {:turn m.turn
   :running? m.running?
   :mailbox (icollect [_ item (ipairs m.mailbox)] item)
   :follow-ups (icollect [_ item (ipairs m.follow-ups)] item)
   :modes {:steering m.modes.steering :follow-up m.modes.follow-up}
   :next-id m.next-id
   :idle-start? m.idle-start?})

;; @doc fen.core.tasks.info
;; kind: function
;; signature: (info ?machine) -> {:steering-queued n :follow-up-queued n :steering-mode mode :follow-up-mode mode}
;; summary: Queue depths and drain modes in the status-line field names, for the given machine or the live one.
;; tags: tasks steering status
(fn M.info [?machine]
  (let [m (or ?machine state.machine)]
    {:steering-queued (length m.mailbox)
     :follow-up-queued (length m.follow-ups)
     :steering-mode m.modes.steering
     :follow-up-mode m.modes.follow-up}))

(fn counts [m]
  {:type :counts :info (M.info m)})

(fn reject [reason]
  {:type :ack :status :rejected :reason reason})

(fn new-item! [m ?turn text]
  (let [item {:id m.next-id :turn ?turn :text text}]
    (set m.next-id (+ m.next-id 1))
    item))

(fn take-by-mode! [items mode keep?]
  "Remove items for which keep? is true, honoring the drain mode; return them."
  (let [out []]
    (var i 1)
    (while (<= i (length items))
      (if (and (keep? (. items i)) (or (= mode :all) (= (length out) 0)))
          (table.insert out (table.remove items i))
          (set i (+ i 1))))
    out))

(fn texts [items]
  (icollect [_ item (ipairs items)] item.text))

(fn end-turn! [m outs]
  "Close the running turn: its leftover steering comes back as :returned."
  (let [n m.turn
        leftover (take-by-mode! m.mailbox :all #(= $1.turn n))]
    (set m.running? false)
    (when (> (length leftover) 0)
      (table.insert outs {:type :returned :turn n :texts (texts leftover)}))))

(fn valid-text? [text]
  (and (= (type text) :string) (not= text "")))

(fn queued [item queue]
  {:type :queued :queue queue :id item.id :text item.text})

(fn accept-steer! [m outs text]
  (let [item (new-item! m m.turn text)]
    (table.insert m.mailbox item)
    (table.insert outs {:type :ack
                        :status :accepted
                        :queue :steering
                        :id item.id})
    (table.insert outs (counts m))
    (table.insert outs (queued item :steering))))

(fn accept-follow-up! [m outs text start-if-idle?]
  (let [item (new-item! m nil text)
        start? (and start-if-idle? (not m.running?))]
    (table.insert m.follow-ups item)
    (when start? (set m.idle-start? true))
    (table.insert outs {:type :ack
                        :status :accepted
                        :queue :follow-up
                        :id item.id
                        :start-pending? (when start?
                                          true)})
    (table.insert outs (counts m))
    (table.insert outs (queued item :follow-up))))

(fn last-index [items text]
  (var found nil)
  (each [i item (ipairs items)]
    (when (= item.text text) (set found i)))
  found)

(local STEPS {})

(fn STEPS.turn-start [m _input outs]
  ;; A turn whose end was never reported (its coroutine was abandoned rather
  ;; than resumed to completion) is closed first, so its lines can never reach
  ;; the new turn. The model only starts from idle; this is the same end-then-
  ;; start pair taken in one step.
  (when m.running? (end-turn! m outs))
  (set m.turn (+ m.turn 1))
  (set m.running? true)
  (table.insert outs {:type :started :turn m.turn})
  (table.insert outs (counts m)))

(fn STEPS.turn-end [m input outs]
  (when (and m.running? (or (= input.turn nil) (= input.turn m.turn)))
    (end-turn! m outs)
    (table.insert outs (counts m))))

(fn STEPS.steer [m input outs]
  (if (not (valid-text? input.text))
      (table.insert outs (reject "cannot queue an empty message"))
      (not m.running?)
      (table.insert outs (reject "no turn is running"))
      (and input.turn (not= input.turn m.turn))
      (table.insert outs
                    (reject (.. "turn " (tostring input.turn)
                                " is not the current turn " (tostring m.turn))))
      (accept-steer! m outs input.text)))

(fn STEPS.follow-up [m input outs]
  (if (not (valid-text? input.text))
      (table.insert outs (reject "cannot queue an empty message"))
      (accept-follow-up! m outs input.text input.start-if-idle?)))

(fn STEPS.take-steering [m _input outs]
  (let [n m.turn
        taken (if m.running?
                  (take-by-mode! m.mailbox m.modes.steering #(= $1.turn n))
                  [])]
    (table.insert outs {:type :inject :queue :steering :texts (texts taken)})
    (when (> (length taken) 0) (table.insert outs (counts m)))))

(fn STEPS.take-follow-up [m _input outs]
  ;; Model guard (absInjectFollowUp): only into a running turn, and only once
  ;; that turn's steering is drained, so steering always wins.
  (let [n m.turn
        steering-left? (accumulate [found false _ item (ipairs m.mailbox)]
                         (or found (= item.turn n)))
        taken (if (and m.running? (not steering-left?))
                  (take-by-mode! m.follow-ups m.modes.follow-up #true)
                  [])]
    (table.insert outs {:type :inject :queue :follow-up :texts (texts taken)})
    (when (> (length taken) 0) (table.insert outs (counts m)))))

(fn STEPS.idle-tick [m _input outs]
  (when (and m.idle-start? (not m.running?))
    (set m.idle-start? false)
    ;; Exactly one, whatever the drain mode: once that turn runs, natural
    ;; stops apply the mode to the rest.
    (when (> (length m.follow-ups) 0)
      (let [item (table.remove m.follow-ups 1)]
        (table.insert outs {:type :start-turn :text item.text})
        (table.insert outs (counts m))))))

(fn STEPS.requeue [m input outs]
  (let [from (canonical-queue input.from)
        to (canonical-queue input.to)
        src (if (= from :steering) m.mailbox
                (= from :follow-up) m.follow-ups)]
    (if (or (not src) (not to) (= from to))
        (table.insert outs
                      (reject (.. "cannot move a line from "
                                  (tostring input.from) " to "
                                  (tostring input.to))))
        (and (= to :steering) (not m.running?))
        (table.insert outs (reject "no turn is running"))
        (let [i (last-index src input.text)]
          (if (not i)
              (table.insert outs
                            (reject (.. "line is no longer pending in "
                                        (tostring input.from))))
              (let [item (table.remove src i)]
                (if (= to :steering)
                    (accept-steer! m outs item.text)
                    (accept-follow-up! m outs item.text false))))))))

(fn STEPS.clear [m input outs]
  (let [kind (canonical-queue input.queue)]
    (when (or (= kind nil) (= kind :steering))
      (set m.mailbox []))
    (when (or (= kind nil) (= kind :follow-up))
      (set m.follow-ups [])
      (set m.idle-start? false))
    (table.insert outs (counts m))))

(fn STEPS.set-mode [m input outs]
  (let [kind (canonical-queue input.queue)]
    (if (and kind (. MODES input.mode))
        (do
          (tset m.modes kind input.mode)
          (table.insert outs {:type :ack :status :accepted}))
        (table.insert outs (reject "unknown queue or mode")))))

;; @doc fen.core.tasks.step
;; kind: function
;; signature: (step machine input) -> machine' [output]
;; summary: Pure Mealy step of the turn mailbox. Inputs: :turn-start, :turn-end, :steer, :follow-up, :take-steering, :take-follow-up, :idle-tick, :requeue, :clear, :set-mode. Outputs: :ack, :queued, :counts, :inject, :returned, :started, :start-turn.
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
    :queued (events.emit {:type :queued :queue out.queue :text out.text})
    :returned
    (events.emit {:type :steering-returned :turn out.turn :texts out.texts})))

;; @doc fen.core.tasks.dispatch!
;; kind: function
;; signature: (dispatch! input) -> [output]
;; summary: Advance the live machine by one step and emit its event outputs (:counts as :set-status-info, :queued, :returned as :steering-returned); returns every output for the caller to act on.
;; tags: tasks steering
(fn M.dispatch! [input]
  (let [(m outs) (M.step state.machine input)]
    (set state.machine m)
    (each [_ out (ipairs outs)]
      (emit-output! out))
    outs))

(fn find-output [outs typ]
  (var found nil)
  (each [_ out (ipairs outs)]
    (when (and (not found) (= out.type typ)) (set found out)))
  found)

(fn ack->result [outs ?queue]
  (let [ack (find-output outs :ack)]
    (if (and ack (= ack.status :accepted))
        {:ok true
         :queued true
         :queue (or ack.queue ?queue)
         :id ack.id
         :start-pending? ack.start-pending?}
        {:ok false :error (or (?. ack :reason) "rejected")})))

;; @doc fen.core.tasks.queue!
;; kind: function
;; signature: (queue! kind text ?opts) -> {:ok true :queued true :queue kind :id n}|{:ok false :error msg}
;; summary: Offer a line to the steering mailbox (for opts.turn, default the running turn) or the follow-up queue (opts.start-if-idle? requests an idle start).
;; tags: tasks steering
(fn M.queue! [kind text ?opts]
  (let [opts (or ?opts {})
        kind (canonical-queue kind)]
    (if (= kind :steering)
        (ack->result (M.dispatch! {:type :steer : text :turn opts.turn}))
        (= kind :follow-up)
        (ack->result (M.dispatch! {:type :follow-up
                                   : text
                                   :start-if-idle? opts.start-if-idle?}))
        {:ok false :error "unknown queue"})))

;; @doc fen.core.tasks.steer-or-follow-up!
;; kind: function
;; signature: (steer-or-follow-up! text) -> {:ok true :queued true :queue kind :id n}|{:ok false :error msg}
;; summary: Busy-time input: steer the running mailbox turn, or, when the session is busy without one (a /reload or /handoff coroutine), queue a follow-up so the line runs next instead of being lost.
;; tags: tasks steering
(fn M.steer-or-follow-up! [text]
  (if state.machine.running?
      (M.queue! :steering text)
      (M.queue! :follow-up text)))

;; @doc fen.core.tasks.take!
;; kind: function
;; signature: (take! kind) -> [text]
;; summary: Drain lines by mode for injection: steering only for the running turn, follow-ups from the shared queue.
;; tags: tasks steering agent
(fn M.take! [kind]
  (let [typ (if (= (canonical-queue kind) :steering) :take-steering
                :take-follow-up)
        out (find-output (M.dispatch! {:type typ}) :inject)]
    (or (?. out :texts) [])))

;; @doc fen.core.tasks.turn-start!
;; kind: function
;; signature: (turn-start!) -> n
;; summary: Open the next main turn and return its number.
;; tags: tasks turn
(fn M.turn-start! []
  (M.dispatch! {:type :turn-start})
  state.machine.turn)

;; @doc fen.core.tasks.turn-end!
;; kind: function
;; signature: (turn-end! ?n) -> [text]|nil
;; summary: Close turn n (default the running one); returns its handed-back steering lines, also emitted as :steering-returned. No-op for a turn already closed.
;; tags: tasks turn
(fn M.turn-end! [?n]
  (?. (find-output (M.dispatch! {:type :turn-end :turn ?n}) :returned) :texts))

;; @doc fen.core.tasks.idle-tick!
;; kind: function
;; signature: (idle-tick!) -> text|nil
;; summary: At an idle safe boundary, pop the one follow-up an idle enqueue asked to start.
;; tags: tasks steering runtime
(fn M.idle-tick! []
  (?. (find-output (M.dispatch! {:type :idle-tick}) :start-turn) :text))

;; @doc fen.core.tasks.requeue!
;; kind: function
;; signature: (requeue! text from to) -> {:ok true :queued true :queue kind}|{:ok false :error msg}
;; summary: Move the most recent pending copy of a line to the other queue; moving to steering needs a running turn.
;; tags: tasks steering
(fn M.requeue! [text from to]
  (ack->result (M.dispatch! {:type :requeue : text : from : to})))

;; @doc fen.core.tasks.clear!
;; kind: function
;; signature: (clear! ?kind) -> nil
;; summary: Empty the named queue, or both when kind is nil or :all.
;; tags: tasks steering
(fn M.clear! [?kind]
  (M.dispatch! {:type :clear :queue (canonical-queue ?kind)})
  nil)

;; @doc fen.core.tasks.set-mode!
;; kind: function
;; signature: (set-mode! kind mode) -> ok?
;; summary: Set a queue's drain mode to :one-at-a-time or :all.
;; tags: tasks steering
(fn M.set-mode! [kind mode]
  (= :accepted (?. (find-output (M.dispatch! {:type :set-mode
                                              :queue kind
                                              : mode})
                                :ack) :status)))

;; @doc fen.core.tasks.snapshot
;; kind: function
;; signature: (snapshot) -> {:turn n :running? bool :steering [text] :follow-up [text] :steering-mode mode :follow-up-mode mode}
;; summary: Copied queue texts, modes, and turn for UI rendering such as the /queue panel.
;; tags: tasks steering introspect
(fn M.snapshot []
  (let [m state.machine]
    {:turn m.turn
     :running? m.running?
     :steering (texts m.mailbox)
     :follow-up (texts m.follow-ups)
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
    (set state.machine.idle-start? false)))

;; @doc fen.core.tasks.reset!
;; kind: function
;; signature: (reset!) -> nil
;; summary: Restore the initial machine; for tests.
;; tags: tasks testing
(fn M.reset! []
  (set state.machine {:turn 0
                      :running? false
                      :mailbox []
                      :follow-ups []
                      :modes {:steering :one-at-a-time
                              :follow-up :one-at-a-time}
                      :next-id 1
                      :idle-start? false})
  (set state.attached? false))

M
