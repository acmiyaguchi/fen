;; fen.core.tasks: the turn-mailbox Mealy step (spec/core/tasks requestsSpec).

(local tasks (require :fen.core.tasks))
(local events (require :fen.core.extensions.events))

(fn initial []
  {:turn 0
   :running? false
   :mailbox []
   :follow-ups []
   :modes {:steering :one-at-a-time :follow-up :one-at-a-time}
   :next-id 1
   :idle-start? false})

(fn run [m inputs]
  "Fold inputs through the pure step; return the final machine and all outputs."
  (var cur m)
  (let [all []]
    (each [_ input (ipairs inputs)]
      (let [(m2 outs) (tasks.step cur input)]
        (set cur m2)
        (each [_ o (ipairs outs)] (table.insert all o))))
    (values cur all)))

(fn of-type [outs typ]
  (icollect [_ o (ipairs outs)] (when (= o.type typ) o)))

(describe "fen.core.tasks.step"
          (fn []
            (it "is pure: the input machine is never mutated"
                (fn []
                  (let [m (initial)
                        (m2 _) (tasks.step m {:type :turn-start})
                        (m3 _) (tasks.step m2 {:type :steer :text "x"})]
                    (assert.are.same (initial) m)
                    (assert.are.equal 0 (length m2.mailbox))
                    (assert.are.equal 1 (length m3.mailbox)))))
            (it "rejects steering when no turn runs, or for a stale turn"
                (fn []
                  (let [(m outs) (run (initial)
                                      [{:type :steer :text "idle"}
                                       {:type :turn-start}
                                       {:type :turn-start}
                                       {:type :steer :text "stale" :turn 1}
                                       {:type :steer :text ""}])
                        acks (of-type outs :ack)]
                    (assert.are.equal 3 (length acks))
                    (each [_ a (ipairs acks)]
                      (assert.are.equal :rejected a.status))
                    (assert.are.equal 0 (length m.mailbox)))))
            (it "injects steering only into the turn it was accepted for"
                (fn []
                  (let [(m outs) (run (initial)
                                      [{:type :turn-start}
                                       {:type :steer :text "a"}
                                       {:type :steer :text "b" :turn 1}
                                       {:type :take-steering}
                                       {:type :take-steering}
                                       {:type :take-steering}])
                        injects (of-type outs :inject)]
                    (assert.are.same [["a"] ["b"] []]
                                     (icollect [_ o (ipairs injects)] o.texts))
                    (assert.are.equal 0 (length m.mailbox)))))
            (it "hands leftover steering back at every turn end and never leaks it"
                (fn []
                  (each [_ ending (ipairs [{:type :turn-end}
                                           {:type :turn-end :turn 1}
                                           ;; an unreported end is closed by the next start
                                           {:type :turn-start}])]
                    (let [(m outs) (run (initial)
                                        [{:type :turn-start}
                                         {:type :steer :text "late"}
                                         ending
                                         {:type :turn-start}
                                         {:type :take-steering}])
                          returned (of-type outs :returned)
                          injects (of-type outs :inject)]
                      (assert.are.same [{:type :returned
                                         :turn 1
                                         :texts ["late"]}]
                                       returned)
                      (assert.are.same [] (. injects 1 :texts))
                      (assert.are.equal 0 (length m.mailbox))))))
            (it "ignores a turn end for a turn that is not running"
                (fn []
                  (let [(m outs) (run (initial)
                                      [{:type :turn-start}
                                       {:type :turn-start}
                                       {:type :steer :text "keep"}
                                       {:type :turn-end :turn 1}])]
                    (assert.is_true m.running?)
                    (assert.are.equal 1 (length m.mailbox))
                    (assert.are.equal 0 (length (of-type outs :returned))))))
            (it "keeps follow-ups across turn end"
                (fn []
                  (let [(m _) (run (initial)
                                   [{:type :turn-start}
                                    {:type :follow-up :text "next"}
                                    {:type :turn-end}])]
                    (assert.are.equal 1 (length m.follow-ups)))))
            (it "drains by mode: one at a time by default, all after set-mode"
                (fn []
                  (let [(_ outs) (run (initial)
                                      [{:type :turn-start}
                                       {:type :follow-up :text "a"}
                                       {:type :follow-up :text "b"}
                                       {:type :follow-up :text "c"}
                                       {:type :take-follow-up}
                                       {:type :set-mode
                                        :queue :follow-up
                                        :mode :all}
                                       {:type :take-follow-up}])]
                    (assert.are.same [["a"] ["b" "c"]]
                                     (icollect [_ o (ipairs (of-type outs
                                                                     :inject))]
                                       o.texts)))))
            (it "idle tick starts exactly one requested follow-up, only when idle"
                (fn []
                  (let [(m outs) (run (initial)
                                      [{:type :follow-up
                                        :text "a"
                                        :start-if-idle? true}
                                       {:type :follow-up :text "b"}
                                       {:type :idle-tick}
                                       {:type :idle-tick}])]
                    (assert.are.same [{:type :start-turn :text "a"}]
                                     (of-type outs :start-turn))
                    (assert.are.equal 1 (length m.follow-ups))))
                (let [(m _) (run (initial)
                                 [{:type :turn-start}
                                  {:type :follow-up
                                   :text "a"
                                   :start-if-idle? true}])]
                  (assert.is_false m.idle-start?)))
            (it "requeue moves the latest copy; steering needs a running turn"
                (fn []
                  (let [(m outs) (run (initial)
                                      [{:type :turn-start}
                                       {:type :steer :text "a"}
                                       {:type :steer :text "a"}
                                       {:type :requeue
                                        :text "a"
                                        :from :steering
                                        :to :follow-up}
                                       {:type :turn-end}
                                       {:type :requeue
                                        :text "a"
                                        :from :follow-up
                                        :to :steering}])
                        acks (of-type outs :ack)]
                    (assert.are.equal :accepted (. acks 3 :status))
                    (assert.are.equal :rejected (. acks 4 :status))
                    (assert.are.same [["a"]]
                                     (icollect [_ o (ipairs (of-type outs
                                                                     :returned))]
                                       o.texts))
                    (assert.are.equal 1 (length m.follow-ups)))))
            (it "clear empties one queue or both and drops a pending idle start"
                (fn []
                  (let [(m _) (run (initial)
                                   [{:type :follow-up
                                     :text "f"
                                     :start-if-idle? true}
                                    {:type :turn-start}
                                    {:type :steer :text "s"}
                                    {:type :clear :queue :steering}])]
                    (assert.are.equal 0 (length m.mailbox))
                    (assert.are.equal 1 (length m.follow-ups))
                    (assert.is_true m.idle-start?)
                    (let [(m2 _) (tasks.step m {:type :clear})]
                      (assert.are.equal 0 (length m2.follow-ups))
                      (assert.is_false m2.idle-start?)))))
            (it "take-follow-up refuses the model's forbidden transitions"
                (fn []
                  ;; idle: nothing to inject into
                  (let [(m outs) (run (initial)
                                      [{:type :follow-up :text "f"}
                                       {:type :take-follow-up}])]
                    (assert.are.same [] (. (of-type outs :inject) 1 :texts))
                    (assert.are.equal 1 (length m.follow-ups)))
                  ;; running with steering still queued: steering wins
                  (let [(m outs) (run (initial)
                                      [{:type :turn-start}
                                       {:type :follow-up :text "f"}
                                       {:type :steer :text "s"}
                                       {:type :take-follow-up}])]
                    (assert.are.same [] (. (of-type outs :inject) 1 :texts))
                    (assert.are.equal 1 (length m.follow-ups)))))
            (it "rejects unknown inputs without changing state"
                (fn []
                  (let [(m outs) (tasks.step (initial) {:type :bogus})]
                    (assert.are.same (initial) m)
                    (assert.are.equal :rejected (. outs 1 :status)))))))

(describe "fen.core.tasks.dispatch!"
          (fn []
            (before_each (fn [] (tasks.reset!)))
            (after_each (fn [] (tasks.reset!)))
            (it "emits :queued, status counts, and :steering-returned on the bus"
                (fn []
                  (let [seen []]
                    (each [_ t (ipairs [:queued
                                        :set-status-info
                                        :steering-returned])]
                      (events.on t #(table.insert seen $1.type) :tasks-test))
                    (let [n (tasks.turn-start!)]
                      (assert.is_true (. (tasks.queue! :steering "x") :ok))
                      (assert.are.same ["x"] (tasks.turn-end! n)))
                    (assert.is_truthy (. (icollect [_ t (ipairs seen)]
                                           (when (= t :steering-returned) t))
                                         1))
                    (assert.is_truthy (. (icollect [_ t (ipairs seen)]
                                           (when (= t :queued) t))
                                         1))
                    (events.unregister-by-owner :tasks-test))))))
