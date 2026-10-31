;; Known-bug probe for #634 (downstream of agent-loop #609): when a goal
;; iteration hits the tool-call safety cap, turn_lifecycle reports :ok because
;; the last message is a tool result, so the goal runs handle-success! on the
;; "[error] tool-call loop exceeded safety cap" text, ends blocked ("missing
;; GOAL_STATUS marker") and exits 2 instead of failing with 1.
;; See spec/presenters/FINDINGS.md (#634).

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local types (require :fen.core.types))
(local turn-lifecycle (require :fen.turn_lifecycle))
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

(local CAP-TEXT "[error] tool-call loop exceeded safety cap")

(fn cap-event []
  "The real lifecycle event for what agent.step leaves after the cap: the
   last message is a tool result and the step returned CAP-TEXT."
  (let [agent {:messages [(types.user-message "go")
                          (types.assistant-message {:content [(types.tool-call-block "c1"
                                                                                     :read
                                                                                     {})]
                                                    :stop-reason :tool-use})
                          (types.tool-result-message {:tool-call-id "c1"
                                                      :tool-name :read
                                                      :content [(types.text-block "ok")]})]}
        ev (turn-lifecycle.complete-event {: agent} true CAP-TEXT)]
    {:status ev.status :result ev.result :error ev.error}))

(describe "#634 goal outcome after the safety cap"
          (fn []
            (it "exits 2 (blocked) with the cap error as final-text"
                (fn []
                  (known-bug 634
                             (fn []
                               (let [ev (cap-event)
                                     r (run-goal [ev])]
                                 (and (= :ok ev.status) (= 2 r.code)
                                      (= "blocked" r.blob.goal.status)
                                      (= "missing GOAL_STATUS marker"
                                         r.blob.goal.reason)
                                      (= CAP-TEXT r.blob.final-text)))))))))
