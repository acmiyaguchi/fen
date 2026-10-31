;; Regression test for #634 (spec/presenters/FINDINGS.md, downstream of
;; agent-loop #609/#610): a goal iteration that hits the tool-call safety cap
;; fails (exit 1) with no final text. turn_lifecycle reports the step's own
;; :error Outcome, though the last message is a tool result.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local types (require :fen.core.types))
(local turn-lifecycle (require :fen.turn_lifecycle))
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

(local CAP-ERROR "tool-call loop exceeded safety cap")
(local CAP-TEXT (.. "[error] " CAP-ERROR))

(fn cap-event []
  "The real lifecycle event for what agent.step leaves after the cap: the
   last message is a tool result, and step recorded an :error Outcome."
  (let [agent {:messages [(types.user-message "go")
                          (types.assistant-message {:content [(types.tool-call-block "c1"
                                                                                     :read
                                                                                     {})]
                                                    :stop-reason :tool-use})
                          (types.tool-result-message {:tool-call-id "c1"
                                                      :tool-name :read
                                                      :content [(types.text-block "ok")]})]
               :outcome (types.outcome :error CAP-TEXT CAP-ERROR)}
        ev (turn-lifecycle.complete-event {: agent} true CAP-TEXT)]
    {:status ev.status :result ev.result :error ev.error}))

(describe "goal outcome after the safety cap (#634)"
          (fn []
            (it "exits 1 (failure) with no final text"
                (fn []
                  (let [ev (cap-event)
                        r (run-goal [ev])]
                    (assert.are.equal :error ev.status)
                    (assert.are.equal CAP-ERROR ev.error)
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "failure" r.blob.goal.status)
                    (assert.is_nil r.blob.final-text))))))
