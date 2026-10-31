;; Regression test for #633 (spec/presenters/FINDINGS.md): a goal whose last
;; iteration fails or is cancelled reports no final text, not the previous
;; iteration's; last-result still keeps that text for `/goal resume`.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local json (require :fen.util.json))

;; Drive the real goal companion and the real goal_headless presenter. Each
;; on-tick delivers the next scripted :agent-turn-complete for the turn the
;; goal submitted. Returns {:code :blob :goal}; the JSON outcome file is removed.
(fn run-goal [iterations]
  (test-api.reset!)
  (tset package.loaded :fen.extensions.goal nil)
  (tset package.loaded :fen.extensions.goal.state nil)
  (tset package.loaded :fen.extensions.goal_headless nil)
  (let [goal (require :fen.extensions.goal)
        presenter (require :fen.extensions.goal_headless)
        goal-state (require :fen.extensions.goal.state)
        api (test-api.make-runtime-api :goal)
        turn-id {:value 0}
        run-state {:agent {:messages []}
                   :submit-user-turn! (fn [_text _opts]
                                        (set turn-id.value (+ turn-id.value 1))
                                        {:ok true
                                         :started? true
                                         :turn-id turn-id.value})}
        out-path (os.tmpname)
        script {:i 0}
        ctx {:state {:opts {:objective "ship it"
                            :max-iterations 2
                            :json-output-file out-path}
                     :agent run-state.agent}
             :on-submit (fn [line] (command-registry.dispatch line run-state))
             :is-busy? (fn [] (= goal-state.status :running))
             :on-tick (fn []
                        (set script.i (+ script.i 1))
                        (let [ev (assert (. iterations script.i)
                                         "goal asked for more iterations")]
                          (set ev.type :agent-turn-complete)
                          (set ev.agent run-state.agent)
                          (set ev.turn-id goal._state.active-turn-id)
                          (events.emit ev)))}]
    (goal.register api)
    (let [code (presenter.run ctx)
          f (assert (io.open out-path :r))
          blob (json.decode (f:read :*a))]
      (f:close)
      (os.remove out-path)
      (test-api.reset!)
      {: code : blob :goal goal-state})))

(local ITER-1 "Iter one text.\nGOAL_STATUS: continue")

(describe "goal final-text after a failed iteration (#633)"
          (fn []
            (it "is absent when iteration 2 errors"
                (fn []
                  (let [r (run-goal [{:status :ok :result ITER-1}
                                     {:status :error
                                      :error "usage_limit_reached: quota"}])]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "failure" r.blob.goal.status)
                    (assert.is_nil r.blob.final-text)
                    (assert.are.equal ITER-1 r.goal.last-result))))
            (it "is absent when iteration 2 is cancelled"
                (fn []
                  (let [r (run-goal [{:status :ok :result ITER-1}
                                     {:status :cancelled}])]
                    (assert.are.equal 2 r.code)
                    (assert.are.equal "blocked" r.blob.goal.status)
                    (assert.is_nil r.blob.final-text))))
            (it "is the last iteration's text when the goal finishes"
                (fn []
                  (let [r (run-goal [{:status :ok :result ITER-1}
                                     {:status :ok
                                      :result "Shipped.\nGOAL_STATUS: done"}])]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "done" r.blob.goal.status)
                    (assert.are.equal "Shipped.\nGOAL_STATUS: done"
                                      r.blob.final-text))))))
