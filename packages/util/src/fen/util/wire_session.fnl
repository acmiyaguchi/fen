;; Live-child run state machine for the wire protocol (#516).
;;
;; One table answers "what does control C do in state S": the ack status the
;; child sends, the next state, and the action the child performs. A second
;; table covers the child's internal events (turn ends, deadline, fatal
;; errors). The child presenter (`fen.extensions.rpc`) drives it, and a parent
;; mirrors it to derive run status from child events alone.
;;
;; Pure data plus lookups: no persistent state, safe to reload.

(local M {})

;; @doc fen.util.wire_session.STATES
;; kind: data
;; signature: [state]
;; summary: Every run state in lifecycle order: starting, ready, running, closing, finalizing, then the terminal done, cancelled, failed, and timed-out.
;; tags: wire subagent protocol state
(local STATES [:starting :ready :running :closing :finalizing
               :done :cancelled :failed :timed-out])

(local TERMINAL {:done true :cancelled true :failed true :timed-out true})

(local CONTROLS [:prompt :steer :follow-up :finalize :cancel :close])

;; Actions a child performs for an entry:
;;   :start-turn          start a turn with the control's text
;;   :queue-steering      push text onto the existing steering queue
;;   :queue-follow-up     push text onto the existing follow-up queue
;;   :start-finalize-turn run one turn with tool execution disabled
;;   :interrupt-turn      stop the in-flight turn at its next yield
;;   :abort               stop any in-flight turn, then exit with the state
;;   :finish              emit `result`, then `exit done`
;;   :exit                exit with the (terminal) state as status
;;   :none                nothing further
(fn accept [action next] {:status :accepted : action : next})
(fn apply [next] {:status :applied :action :none : next})
(fn reject [reason] {:status :rejected :action :none : reason})

(local CANCEL (accept :abort :cancelled))

;; @doc fen.util.wire_session.TRANSITIONS
;; kind: data
;; signature: {state {control {:status :action :next :reason}}}
;; summary: The (state, control) table. :status is the control-ack status (accepted, applied, or rejected), :next the state after the control (absent when rejected), and :action what the child does.
;; tags: wire subagent protocol state
(local TRANSITIONS
  {:starting {:prompt (reject "child is not ready")
              :steer (reject "child is not ready")
              :follow-up (reject "child is not ready")
              :finalize (reject "child is not ready")
              :close (reject "child is not ready")
              :cancel CANCEL}
   :ready {:prompt (accept :start-turn :running)
           :steer (accept :start-turn :running)
           :follow-up (accept :start-turn :running)
           :finalize (accept :start-finalize-turn :finalizing)
           :close (accept :finish :done)
           :cancel CANCEL}
   :running {:prompt (reject "a turn is running; send steer or follow-up")
             :steer (accept :queue-steering :running)
             :follow-up (accept :queue-follow-up :running)
             :finalize (accept :interrupt-turn :finalizing)
             :close (accept :none :closing)
             :cancel CANCEL}
   :closing {:prompt (reject "run is closing")
             :steer (reject "run is closing")
             :follow-up (reject "run is closing")
             :finalize (accept :interrupt-turn :finalizing)
             :close (apply :closing)
             :cancel CANCEL}
   :finalizing {:prompt (reject "run is finalizing")
                :steer (reject "run is finalizing")
                :follow-up (reject "run is finalizing")
                :finalize (apply :finalizing)
                :close (apply :finalizing)
                :cancel CANCEL}})

(each [state _ (pairs TERMINAL)]
  (let [row {}]
    (each [_ control (ipairs CONTROLS)]
      (tset row control (reject (.. "run is " state))))
    (tset TRANSITIONS state row)))

;; Internal child events, not controls:
;;   :started          initialization finished (the child emits `ready`)
;;   :turn-done        a regular or interrupted turn ended
;;   :final-turn-done  the tool-free finalize turn ended
;;   :deadline         the run deadline passed
;;   :fatal            an unrecoverable error (e.g. wire version mismatch)
(fn go [action next] {: action : next})

(local ABORT-EVENTS {:deadline (go :abort :timed-out)
                     :fatal (go :abort :failed)})

;; @doc fen.util.wire_session.EVENTS
;; kind: data
;; signature: {state {event {:action :next}}}
;; summary: The (state, internal event) table for turn ends, the deadline, and fatal errors; a missing entry means the event cannot happen in that state.
;; tags: wire subagent protocol state
(local EVENTS
  {:starting {:started (go :none :ready)}
   :ready {}
   :running {:turn-done (go :none :ready)}
   :closing {:turn-done (go :finish :done)}
   :finalizing {:turn-done (go :start-finalize-turn :finalizing)
                :final-turn-done (go :finish :done)}})

(each [state row (pairs EVENTS)]
  (each [event entry (pairs ABORT-EVENTS)]
    (tset row event entry)))

;; An aborted turn unwinds, or throws, after the state is already terminal;
;; a turn end exits with the terminal status, and a later deadline or fatal
;; error keeps waiting for the in-flight turn to unwind (or exits if none).
(each [state _ (pairs TERMINAL)]
  (tset EVENTS state {:turn-done (go :exit state)
                      :final-turn-done (go :exit state)
                      :deadline (go :abort state)
                      :fatal (go :abort state)}))

(fn copy [t]
  (let [out {}]
    (each [k v (pairs t)] (tset out k v))
    out))

;; @doc fen.util.wire_session.decide
;; kind: function
;; signature: (decide state control-type) -> {:status :action :next :reason}
;; summary: Look up the transition for CONTROL-TYPE in STATE. Unknown states or controls are rejected; the returned entry is a copy.
;; tags: wire subagent protocol state
(fn M.decide [state control-type]
  (let [entry (?. TRANSITIONS state control-type)]
    (if entry
        (copy entry)
        (reject (.. "no transition for " (tostring control-type)
                    " in state " (tostring state))))))

;; @doc fen.util.wire_session.advance
;; kind: function
;; signature: (advance state event) -> {:action :next}|nil
;; summary: Look up the internal-event transition for EVENT in STATE, or nil when that event cannot occur there.
;; tags: wire subagent protocol state
(fn M.advance [state event]
  (let [entry (?. EVENTS state event)]
    (when entry (copy entry))))

;; @doc fen.util.wire_session.terminal?
;; kind: function
;; signature: (terminal? state) -> boolean
;; summary: True for done, cancelled, failed, and timed-out; the terminal state is also the `exit` status.
;; tags: wire subagent protocol state
(fn M.terminal? [state]
  (= true (. TERMINAL state)))

;; Wire event types that belong to the run lifecycle rather than the
;; forwarded display stream; a child never forwards bus events of these types.
(local LIFECYCLE-EVENTS {:ready true :turn-started true :turn-complete true
                         :control-ack true :result true :exit true})

;; @doc fen.util.wire_session.lifecycle-event?
;; kind: function
;; signature: (lifecycle-event? type) -> boolean
;; summary: True for the lifecycle wire events (ready, turn-started, turn-complete, control-ack, result, exit) that only the child's run loop emits.
;; tags: wire subagent protocol state
(fn M.lifecycle-event? [typ]
  (= true (. LIFECYCLE-EVENTS typ)))

(set M.STATES STATES)
(set M.CONTROLS CONTROLS)
(set M.TRANSITIONS TRANSITIONS)
(set M.EVENTS EVENTS)

M
