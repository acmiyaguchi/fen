(local json (require :fen.util.json))
(local goal-state (require :fen.extensions.goal.state))
(local presenter (require :fen.extensions.goal_headless))

(fn reset! []
  (set goal-state.status :idle)
  (set goal-state.last-result nil)
  (set goal-state.last-reason nil)
  (set goal-state.iteration-count 0))

(fn capture-stdout [f]
  (let [previous io.write
        chunks []]
    (set io.write (fn [text] (table.insert chunks text)))
    (let [(ok? value) (pcall f)]
      (set io.write previous)
      (if ok? (table.concat chunks) (error value)))))

(fn final-status-line [text]
  (string.match text ".*(GOAL_STATUS: [^\n]+)"))

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
                      (set goal-state.last-reason terminal.reason)
                      (set goal-state.iteration-count (or terminal.iterations 1))
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
              code {:value nil}
              stdout (capture-stdout #(set code.value (presenter.run fixture.ctx)))]
          (assert.are.equal 0 code.value)
          (assert.are.equal "GOAL_STATUS: done" (final-status-line stdout))
          (assert.are.equal 1 fixture.ticks.value)
          (assert.are.equal "/goal start --max-iterations 4 -- ship the feature"
                            (. fixture.submitted 1)))))

    (it "protects option-like objectives from slash-command reparsing"
      (fn []
        (let [opts {:objective "--max-iterations 20 work" :max-iterations 3}]
          (assert.are.equal
            "/goal start --max-iterations 3 -- --max-iterations 20 work"
            (presenter._test.command-for opts)))))

    (it "uses a distinct incomplete exit status"
      (fn []
        (let [fixture (context {:status :blocked
                                :result "needs input\nGOAL_STATUS: blocked"})]
          (assert.are.equal 2 (presenter.run fixture.ctx)))))

    (it "uses failure status for goal errors"
      (fn []
        (let [fixture (context {:status :error
                                :result "failed\nGOAL_STATUS: error"})
              code {:value nil}
              stdout (capture-stdout #(set code.value (presenter.run fixture.ctx)))]
          (assert.are.equal 1 code.value)
          (assert.are.equal "GOAL_STATUS: error" (final-status-line stdout)))))

    (it "maps every terminal goal state to its documented outcome status"
      (fn []
        (assert.are.equal "done" (presenter._test.outcome-status :done))
        (assert.are.equal "blocked" (presenter._test.outcome-status :blocked))
        (assert.are.equal "iteration-cap" (presenter._test.outcome-status :cap-reached))
        (assert.are.equal "failure" (presenter._test.outcome-status :error))))

    (it "writes a blocked terminal marker when the iteration cap is reached"
      (fn []
        (let [fixture (context {:status :cap-reached
                                :result "partial work\nGOAL_STATUS: continue"})
              code {:value nil}
              stdout (capture-stdout #(set code.value (presenter.run fixture.ctx)))]
          (assert.are.equal 2 code.value)
          (assert.are.equal "GOAL_STATUS: blocked" (final-status-line stdout)))))

    (it "writes the goal outcome with named JSON fields"
      (fn []
        (let [out-path (os.tmpname)
              fixture (context {:status :cap-reached
                                :reason "iteration cap reached"
                                :iterations 4
                                :result "partial work\nGOAL_STATUS: continue"})]
          (set (. fixture.ctx :state :opts :json-output-file) out-path)
          (assert.are.equal 2 (presenter.run fixture.ctx))
          (let [f (assert (io.open out-path :r))
                blob (json.decode (f:read :*a))]
            (f:close)
            (os.remove out-path)
            (assert.are.equal "partial work\nGOAL_STATUS: continue" blob.final-text)
            (assert.are.equal "iteration-cap" (. blob :goal :status))
            (assert.are.equal "iteration cap reached" (. blob :goal :reason))
            (assert.are.equal 4 (. blob :goal :iterations-used))
            (assert.are.equal :number (type (. blob :goal :wall-clock-ms)))))))

    (it "forces exit 1 when the JSON write fails"
      (fn []
        (let [previous io.open
              fixture (context {:status :done
                                :result "finished\nGOAL_STATUS: done"})]
          (set (. fixture.ctx :state :opts :json-output-file) "/tmp/fen-goal-writefail")
          ;; Mock a file whose write reports a short/failed write (nil,err),
          ;; as Lua 5.4 does on a full disk. run must not report success.
          (set io.open (fn [_ _]
                         {:write (fn [_ _ _] (values nil "disk full"))
                          :close (fn [_] true)}))
          (let [(ok? code) (pcall (fn [] (presenter.run fixture.ctx)))]
            (set io.open previous)
            (assert.is_true ok?)
            (assert.are.equal 1 code)))))

    (it "forces exit 1 when closing the JSON file fails"
      (fn []
        (let [previous io.open
              fixture (context {:status :done
                                :result "finished\nGOAL_STATUS: done"})]
          (set (. fixture.ctx :state :opts :json-output-file) "/tmp/fen-goal-closefail")
          (set io.open (fn [_ _]
                         {:write (fn [_ _ _] true)
                          :close (fn [_] (values nil "flush failed"))}))
          (let [(ok? code) (pcall (fn [] (presenter.run fixture.ctx)))]
            (set io.open previous)
            (assert.is_true ok?)
            (assert.are.equal 1 code)))))

    (it "returns failure when the goal is nonterminal and idle"
      (fn []
        (let [ctx {:state {:opts {:objective "work" :max-iterations 3}}
                   :on-submit (fn [_] (set goal-state.status :running))
                   :is-busy? (fn [] false)
                   :on-tick (fn [] nil)}]
          (assert.are.equal 1 (presenter.run ctx)))))))
