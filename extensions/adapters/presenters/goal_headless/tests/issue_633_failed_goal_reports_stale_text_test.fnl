;; Known-bug probe for #633: the goal companion sets last-result only in
;; handle-success!, so when an iteration fails or is cancelled the headless
;; outcome reports the previous successful iteration's text as final-text.
;; See spec/presenters/FINDINGS.md (#633).

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local json (require :fen.util.json))
(local {: known-bug} (require :fen.testing))

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

(describe "#633 goal final-text after a failed iteration"
          (fn []
            (it "reports iteration 1's text when iteration 2 errors"
                (fn []
                  (known-bug 633
                             (fn []
                               (let [r (run-goal [{:status :ok :result ITER-1}
                                                  {:status :error
                                                   :error "usage_limit_reached: quota"}])]
                                 (and (= 1 r.code)
                                      (= "failure" r.blob.goal.status)
                                      (= ITER-1 r.blob.final-text)))))))
            (it "reports iteration 1's text when iteration 2 is cancelled"
                (fn []
                  (known-bug 633
                             (fn []
                               (let [r (run-goal [{:status :ok :result ITER-1}
                                                  {:status :cancelled}])]
                                 (and (= 2 r.code)
                                      (= "blocked" r.blob.goal.status)
                                      (= ITER-1 r.blob.final-text)))))))))
