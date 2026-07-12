(local goal-state (require :fen.extensions.goal.state))
(local presenter (require :fen.extensions.goal_headless))

(fn reset! []
  (set goal-state.status :idle)
  (set goal-state.last-result nil))

(fn context [terminal]
  (let [ticks {:value 0}
        busy {:value false}
        submitted []
        state {:opts {:objective "ship the feature" :max-iterations 4}}]
    {:ctx {:state state
           :on-submit (fn [line]
                        (table.insert submitted line)
                        (set goal-state.status :running)
                        (set busy.value true))
           :is-busy? (fn [] busy.value)
           :on-tick (fn []
                      (set ticks.value (+ ticks.value 1))
                      (set goal-state.last-result terminal.result)
                      (set goal-state.status terminal.status)
                      (set busy.value false))}
     :submitted submitted
     :ticks ticks}))

(describe "extensions.goal_headless"
  (fn []
    (before_each reset!)

    (it "starts the existing goal command and drains it to done"
      (fn []
        (let [fixture (context {:status :done
                                :result "finished\nGOAL_STATUS: done"})
              code (presenter.run fixture.ctx)]
          (assert.are.equal 0 code)
          (assert.are.equal 1 fixture.ticks.value)
          (assert.are.equal "/goal start --max-iterations 4 ship the feature"
                            (. fixture.submitted 1)))))

    (it "uses a distinct incomplete exit status"
      (fn []
        (let [fixture (context {:status :blocked
                                :result "needs input\nGOAL_STATUS: blocked"})]
          (assert.are.equal 2 (presenter.run fixture.ctx)))))

    (it "uses failure status for goal errors"
      (fn []
        (let [fixture (context {:status :error
                                :result "failed\nGOAL_STATUS: error"})]
          (assert.are.equal 1 (presenter.run fixture.ctx)))))

    (it "fails rather than spinning when the goal is nonterminal and idle"
      (fn []
        (let [ctx {:state {:opts {:objective "work" :max-iterations 3}}
                   :on-submit (fn [_] (set goal-state.status :running))
                   :is-busy? (fn [] false)
                   :on-tick (fn [] nil)}]
          (assert.has_error (fn [] (presenter.run ctx))
                            "goal stopped making progress without a terminal status"))))))
