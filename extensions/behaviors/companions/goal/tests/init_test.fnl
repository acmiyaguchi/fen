(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))

(fn fresh []
  (test-api.reset!)
  (tset package.loaded :fen.extensions.goal nil)
  (tset package.loaded :fen.extensions.goal.state nil)
  (let [seen []
        submitted []]
    (events.on :* (fn [ev] (table.insert seen ev)))
    (let [goal (require :fen.extensions.goal)
          api (test-api.make-runtime-api :goal)
          run-state {:agent {:messages []}
                     :submit-user-turn! (fn [text opts]
                                          (table.insert submitted {:text text :opts opts})
                                          {:ok true :started? true})}]
      (goal.register api)
      (values seen submitted goal api run-state))))

(fn registered? [kind name]
  (var found? false)
  (each [_ rec (ipairs (register-registry.list kind))]
    (when (= rec.name name)
      (set found? true)))
  found?)

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(fn status-spec []
  (var found nil)
  (each [_ rec (ipairs (register-registry.list :status))]
    (when (= rec.name :goal)
      (set found rec)))
  found)

(fn panel-spec []
  (var found nil)
  (each [_ rec (ipairs (register-registry.list :panels))]
    (when (= rec.name :goal)
      (set found rec)))
  found)

(fn snapshot []
  (. (register-registry.collect-introspection :goal nil) :goal :state))

(fn install-compact-tool! [api]
  (api.register :tool
    {:name :compact
     :description "test compact"
     :parameters {:type :object}
     :execute (fn [] nil)}))

(fn set-context-estimate! [run-state total]
  (let [agent run-state.agent]
    (set agent.context-token-ledger
         {:system-prompt agent.system-prompt
          :messages-ref agent.messages
          :message-count (length agent.messages)
          :message-tokens []
          :total total})))

(describe "extensions.goal"
  (fn []
    (after_each (fn [] (test-api.reset!)))

    (it "registers command, status, panel, and introspection"
      (fn []
        (fresh)
        (assert.is_true (registered? :commands :goal))
        (assert.is_true (registered? :status :goal))
        (assert.is_true (registered? :panels :goal))
        (assert.is_true (registered? :introspectors :state))))

    (it "/goal starts a bounded goal turn with the requested objective and cap"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 2 ship autonomous runs" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.are.equal :running goal._state.status)
          (assert.are.equal "ship autonomous runs" goal._state.objective)
          (assert.are.equal 1 goal._state.iteration-count)
          (assert.are.equal 2 goal._state.max-iterations)
          (let [text (. submitted 1 :text)]
            (assert.is_truthy (string.find text "bounded autonomous goal workflow" 1 true))
            (assert.is_truthy (string.find text "Objective: ship autonomous runs" 1 true))
            (assert.is_truthy (string.find text "Iteration: 1 of 2" 1 true))
            (assert.is_truthy (string.find text "GOAL_STATUS: continue" 1 true)))
          (assert.are.equal :reject (. submitted 1 :opts :when-busy))
          (assert.is_false (. submitted 1 :opts :emit-user?)))))

    (it "continues until done when the model emits GOAL_STATUS markers"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (assert.are.equal 1 (length submitted))
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Made progress.\nGOAL_STATUS: continue"})
          (assert.are.equal :running goal._state.status)
          (assert.are.equal 2 goal._state.iteration-count)
          (assert.are.equal 2 (length submitted))
          (assert.is_truthy (string.find (. submitted 2 :text) "Previous iteration result:" 1 true))
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Done.\nGOAL_STATUS: done"})
          (assert.are.equal :done goal._state.status)
          (assert.are.equal "done" goal._state.last-marker)
          (assert.are.equal 2 (length submitted)))))

    (it "requires agent compaction before high-context goal work continues"
      (fn []
        (let [(_seen submitted goal api run-state) (fresh)]
          (install-compact-tool! api)
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (set-context-estimate! run-state 90000)
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Need more.\nGOAL_STATUS: continue"})
          (assert.are.equal :running goal._state.status)
          (assert.is_true goal._state.compaction-required?)
          (assert.are.equal 2 (length submitted))
          (assert.is_truthy
            (string.find (. submitted 2 :text) "Before doing any other work, call the compact tool" 1 true))
          (events.emit {:type :compaction-summary
                        :trigger :agent
                        :summary "preserved goal"
                        :tokens-before 90000
                        :tokens-after 21000})
          (assert.is_false goal._state.compaction-required?)
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Done.\nGOAL_STATUS: done"})
          (assert.are.equal :done goal._state.status)
          (assert.are.equal 21000 goal._state.last-compaction.tokens-after))))

    (it "blocks high-context continuation when compact is unavailable"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (set-context-estimate! run-state 90000)
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Need more.\nGOAL_STATUS: continue"})
          (assert.are.equal :blocked goal._state.status)
          (assert.are.equal 1 (length submitted))
          (assert.is_truthy (string.find goal._state.last-reason "compact is unavailable" 1 true)))))

    (it "blocks when required agent compaction does not complete"
      (fn []
        (let [(_seen submitted goal api run-state) (fresh)]
          (install-compact-tool! api)
          (command-registry.dispatch "/goal --max-iterations 2 implement feature" run-state)
          (set-context-estimate! run-state 90000)
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Need more.\nGOAL_STATUS: continue"})
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Skipped it.\nGOAL_STATUS: continue"})
          (assert.are.equal :blocked goal._state.status)
          (assert.is_truthy (string.find goal._state.last-reason "required compaction did not complete" 1 true))
          (events.emit {:type :compaction-summary
                        :trigger :manual
                        :summary "manual recovery"
                        :tokens-before 90000
                        :tokens-after 20000})
          (assert.is_false goal._state.compaction-required?)
          (command-registry.dispatch "/goal resume" run-state)
          (assert.are.equal :running goal._state.status)
          (assert.are.equal 2 goal._state.iteration-count)
          (assert.is_falsy
            (string.find (. submitted 3 :text) "CONTEXT BUDGET GUARD" 1 true)))))

    (it "distinguishes provider context-limit failures from runtime errors"
      (fn []
        (let [(_seen _submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal implement feature" run-state)
          (events.emit {:type :error :error "maximum context length exceeded"})
          (assert.are.equal :running goal._state.status)
          (events.emit {:type :agent-turn-complete
                        :status :error
                        :error "maximum context length exceeded"})
          (assert.are.equal :blocked goal._state.status)
          (assert.is_truthy (string.find goal._state.last-reason "provider context limit" 1 true)))))

    (it "stops at the iteration cap instead of running unbounded"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 1 implement feature" run-state)
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Need more.\nGOAL_STATUS: continue"})
          (assert.are.equal :cap-reached goal._state.status)
          (assert.are.equal 1 goal._state.iteration-count)
          (assert.are.equal 1 (length submitted)))))

    (it "blocks when the status marker is missing"
      (fn []
        (let [(_seen _submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal implement feature" run-state)
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "I forgot the marker"})
          (assert.are.equal :blocked goal._state.status)
          (assert.are.equal "missing GOAL_STATUS marker" goal._state.last-reason))))

    (it "/goal stop prevents future automatic continuation"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (command-registry.dispatch "/goal stop" run-state)
          (assert.are.equal :stopped goal._state.status)
          (events.emit {:type :agent-turn-complete
                        :status :ok
                        :result "Would continue.\nGOAL_STATUS: continue"})
          (assert.are.equal :stopped goal._state.status)
          (assert.are.equal 1 (length submitted)))))

    (it "reports status through command, status item, panel, and introspection"
      (fn []
        (let [(seen _submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 2 implement feature" run-state)
          (command-registry.dispatch "/goal status" run-state)
          (assert.is_truthy (string.find (. (last-event seen :assistant-text) :text) "Goal status: running" 1 true))
          (let [status (status-spec)
                panel (panel-spec)
                snap (snapshot)]
            (assert.are.equal "goal:1/2" (. (status.render {}) :text))
            (assert.is_true (> (panel.height {:w 80}) 0))
            (assert.is_true (> (length (panel.render {:w 80})) 0))
            (assert.are.equal :running snap.status)
            (assert.are.equal "implement feature" snap.objective)
            (assert.are.equal 2 snap.max-iterations)))))

    (it "validates start arguments and iteration caps"
      (fn []
        (let [(seen submitted _goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations nope implement" run-state)
          (assert.are.equal 0 (length submitted))
          (assert.is_truthy (string.find (. (last-event seen :error) :error) "invalid iteration cap" 1 true))
          (command-registry.dispatch "/goal --max-iterations 21 implement" run-state)
          (assert.are.equal 0 (length submitted))
          (assert.is_truthy (string.find (. (last-event seen :error) :error) "<= 20" 1 true)))))

    (it "reset-conversation clears goal state"
      (fn []
        (let [(_seen _submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal implement feature" run-state)
          (assert.are.equal :running goal._state.status)
          (events.emit {:type :reset-conversation})
          (assert.are.equal :idle goal._state.status)
          (assert.is_nil goal._state.objective))))))
