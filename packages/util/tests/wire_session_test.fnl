(local wire (require :fen.util.wire))
(local ws (require :fen.util.wire_session))

;; The expected table, written out independently of the module: every
;; (state, control) pair maps to [status next action].
(local R [:rejected nil :none])
(local CANCEL [:accepted :cancelled :abort])

(local EXPECTED
  {:starting {:prompt R :steer R :follow-up R :finalize R :close R
              :cancel CANCEL}
   :ready {:prompt [:accepted :running :start-turn]
           :steer [:accepted :running :start-turn]
           :follow-up [:accepted :running :start-turn]
           :finalize [:accepted :finalizing :start-finalize-turn]
           :close [:accepted :done :finish]
           :cancel CANCEL}
   :running {:prompt R
             :steer [:accepted :running :queue-steering]
             :follow-up [:accepted :running :queue-follow-up]
             :finalize [:accepted :finalizing :interrupt-turn]
             :close [:accepted :closing :none]
             :cancel CANCEL}
   :closing {:prompt R :steer R :follow-up R
             :finalize [:accepted :finalizing :interrupt-turn]
             :close [:applied :closing :none]
             :cancel CANCEL}
   :finalizing {:prompt R :steer R :follow-up R
                :finalize [:applied :finalizing :none]
                :close [:applied :finalizing :none]
                :cancel CANCEL}
   :done {:prompt R :steer R :follow-up R :finalize R :close R :cancel R}
   :cancelled {:prompt R :steer R :follow-up R :finalize R :close R :cancel R}
   :failed {:prompt R :steer R :follow-up R :finalize R :close R :cancel R}
   :timed-out {:prompt R :steer R :follow-up R :finalize R :close R :cancel R}})

(local EXPECTED-EVENTS
  ;; state -> event -> [next action]; absent pairs cannot happen.
  {:starting {:started [:ready :none]
              :deadline [:timed-out :abort] :fatal [:failed :abort]}
   :ready {:deadline [:timed-out :abort] :fatal [:failed :abort]}
   :running {:turn-done [:ready :none]
             :deadline [:timed-out :abort] :fatal [:failed :abort]}
   :closing {:turn-done [:done :finish]
             :deadline [:timed-out :abort] :fatal [:failed :abort]}
   :finalizing {:turn-done [:finalizing :start-finalize-turn]
                :final-turn-done [:done :finish]
                :deadline [:timed-out :abort] :fatal [:failed :abort]}
   :done {:turn-done [:done :exit] :final-turn-done [:done :exit]}
   :cancelled {:turn-done [:cancelled :exit] :final-turn-done [:cancelled :exit]}
   :failed {:turn-done [:failed :exit] :final-turn-done [:failed :exit]}
   :timed-out {:turn-done [:timed-out :exit] :final-turn-done [:timed-out :exit]}})

(local INTERNAL-EVENTS [:started :turn-done :final-turn-done :deadline :fatal])

(describe "fen.util.wire_session transitions"
  (fn []
    (it "covers exactly the wire control types"
      (fn []
        (let [seen {}]
          (each [_ c (ipairs ws.CONTROLS)]
            (tset seen c true)
            (assert.is_true (wire.control-type? c)))
          (each [c _ (pairs wire.CONTROL-TYPES)]
            (assert.is_true (. seen c) c)))))

    (each [_ state (ipairs ws.STATES)]
      (each [_ control (ipairs ws.CONTROLS)]
        (it (.. state " + " control)
          (fn []
            (let [[status next action] (. EXPECTED state control)
                  entry (ws.decide state control)]
              (assert.are.equal status entry.status)
              (assert.are.equal next entry.next)
              (assert.are.equal action entry.action)
              (if (= status :rejected)
                  (assert.is_string entry.reason)
                  (assert.is_true (not= nil (. EXPECTED entry.next)))))))))

    (it "lets cancel win from every non-terminal state"
      (fn []
        (each [_ state (ipairs ws.STATES)]
          (when (not (ws.terminal? state))
            (assert.are.equal :cancelled (. (ws.decide state :cancel) :next))))))

    (it "keeps finalize idempotent once finalizing"
      (fn []
        (let [first (ws.decide :running :finalize)
              second (ws.decide first.next :finalize)]
          (assert.are.equal :accepted first.status)
          (assert.are.equal :applied second.status)
          (assert.are.equal :finalizing second.next))))

    (it "rejects unknown states and controls instead of throwing"
      (fn []
        (assert.are.equal :rejected (. (ws.decide :ready :bogus) :status))
        (assert.are.equal :rejected (. (ws.decide :bogus :prompt) :status))))

    (it "returns copies so callers cannot mutate the table"
      (fn []
        (let [entry (ws.decide :ready :prompt)]
          (set entry.next :done)
          (assert.are.equal :running (. (ws.decide :ready :prompt) :next)))))))

(describe "fen.util.wire_session internal events"
  (fn []
    (each [_ state (ipairs ws.STATES)]
      (each [_ event (ipairs INTERNAL-EVENTS)]
        (it (.. state " + " event)
          (fn []
            (let [expected (?. EXPECTED-EVENTS state event)
                  entry (ws.advance state event)]
              (if expected
                  (do (assert.are.equal (. expected 1) entry.next)
                      (assert.are.equal (. expected 2) entry.action))
                  (assert.is_nil entry)))))))

    (it "marks exactly the exit statuses terminal"
      (fn []
        (each [_ state (ipairs ws.STATES)]
          (let [exit-status? (not= nil (wire.validate
                                         {:v wire.VERSION :seq 1 :run "r"
                                          :type :exit :status state}
                                         :event))]
            (assert.are.equal exit-status? (ws.terminal? state) state)))))

    (it "names the lifecycle events that are not forwarded display events"
      (fn []
        (each [_ t (ipairs [:ready :turn-started :turn-complete :control-ack
                            :result :exit])]
          (assert.is_true (ws.lifecycle-event? t))
          (assert.is_true (wire.event-type? t)))
        (assert.is_false (ws.lifecycle-event? :tool-call))))))
