(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))

(fn fresh [?session]
  (test-api.reset!)
  (tset package.loaded :fen.extensions.goal nil)
  (tset package.loaded :fen.extensions.goal.state nil)
  (let [seen []
        submitted []
        turn-id {:value 0}]
    (events.on :* (fn [ev] (table.insert seen ev)))
    (let [goal (require :fen.extensions.goal)
          api (test-api.make-runtime-api :goal)
          run-state {:agent {:messages []}
                     :submit-user-turn! (fn [text opts]
                                          (table.insert submitted {:text text :opts opts})
                                          (set turn-id.value (+ turn-id.value 1))
                                          {:ok true :started? true :turn-id turn-id.value})}]
      (when ?session
        (set api.session.info (fn [] {:id ?session.id :path ?session.id}))
        (set api.session.append-state!
             (fn [value version]
               (let [entry {:version version :state value}]
                 (table.insert ?session.entries entry)
                 entry)))
        (set api.session.latest-state
             (fn [?yield-fn ?accept]
               (var found nil)
               (for [i (length ?session.entries) 1 -1 &until found]
                 (let [entry (. ?session.entries i)]
                   (when (or (not ?accept) (?accept entry.state entry))
                     (set found entry))))
               (when found (values found.state found)))))
      (goal.register api)
      (values seen submitted goal api run-state))))

(fn registered? [kind name]
  (var found? false)
  (each [_ rec (ipairs (register-registry.list kind))]
    (when (= rec.name name)
      (set found? true)))
  found?)

(fn emit-turn-complete! [goal ev]
  (set ev.turn-id goal._state.active-turn-id)
  (events.emit ev))

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(fn last-goal-decision [seen]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (= ev.type :info) (= ev.source :goal))
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

    (it "display-reason collapses provider blobs to one clean line"
      (fn []
        (let [(_seen _submitted goal _api _run-state) (fresh)
              display-reason goal._test.display-reason
              blob (.. "server_is_overloaded: Our servers are currently overloaded. "
                       "Please try again later.\n"
                       "Diagnostic: /home/anthony/.local/state/fen/provider-failures/x.json")
              shown (display-reason blob)]
          (assert.is_nil (string.find shown "\n" 1 true))
          (assert.is_nil (string.find shown "Diagnostic:" 1 true))
          (assert.is_nil (string.find shown "provider-failures" 1 true))
          (assert.is_truthy (string.find shown "server_is_overloaded" 1 true)))))

    (it "display-reason skips leading diagnostic-only lines"
      (fn []
        (let [(_seen _submitted goal _api _run-state) (fresh)
              display-reason goal._test.display-reason]
          (assert.are.equal "retryable upstream failure"
                            (display-reason
                              "Diagnostic: /tmp/provider-failures/x.json\nretryable upstream failure"))
          (assert.are.equal "provider diagnostic available"
                            (display-reason
                              "provider failure diagnostic: /tmp/provider-failures/x.json")))))

    (it "display-reason bounds very long single-line reasons"
      (fn []
        (let [(_seen _submitted goal _api _run-state) (fresh)
              display-reason goal._test.display-reason
              shown (display-reason (string.rep "x" 500))]
          (assert.is_true (<= (length shown) 162))
          (assert.is_truthy (string.find shown "…" 1 true)))))

    (it "display-reason returns nil for empty or blank reasons"
      (fn []
        (let [(_seen _submitted goal _api _run-state) (fresh)
              display-reason goal._test.display-reason]
          (assert.is_nil (display-reason nil))
          (assert.is_nil (display-reason ""))
          (assert.is_nil (display-reason "   \n  ")))))

    (it "display-reason preserves short extension reasons unchanged"
      (fn []
        (let [(_seen _submitted goal _api _run-state) (fresh)
              display-reason goal._test.display-reason]
          (assert.are.equal "iteration cap reached" (display-reason "iteration cap reached"))
          (assert.are.equal "stopped by user" (display-reason "stopped by user")))))

    (it "status text, snapshot, and raw state balance clean display with detail flags"
      (fn []
        (let [(_seen _submitted goal _api run-state) (fresh)
              blob (.. "server_error: boom\n"
                       "Diagnostic: /home/anthony/.local/state/fen/provider-failures/y.json")]
          (command-registry.dispatch "/goal implement feature" run-state)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :error
                        :error blob})
          (assert.are.equal :error goal._state.status)
          ;; Raw detail is retained internally for logic and debugging.
          (assert.are.equal blob goal._state.last-error)
          (assert.is_truthy (string.find goal._state.last-reason "Diagnostic:" 1 true))
          ;; User-facing /goal status stays compact.
          (let [text (goal._test.status-text)]
            (assert.is_nil (string.find text "Diagnostic:" 1 true))
            (assert.is_nil (string.find text "provider-failures" 1 true))
            (assert.is_truthy (string.find text "Reason: server_error: boom" 1 true)))
          ;; The goal introspection snapshot is also user-facing; it should not
          ;; leak local diagnostic paths, but should say more detail exists.
          (let [snap (snapshot)]
            (assert.are.equal "server_error: boom" snap.last-error)
            (assert.are.equal "server_error: boom" snap.last-reason)
            (assert.is_true snap.last-error-detail?)
            (assert.is_true snap.last-reason-detail?)))))

    (it "/goal start disambiguates objectives beginning with command words"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal start status" run-state)
          (assert.are.equal 1 (length submitted))
          (assert.are.equal :running goal._state.status)
          (assert.are.equal "status" goal._state.objective))))

    (it "/goal start preserves option-like objective text after --"
      (fn []
        (let [(_seen _submitted goal _api run-state) (fresh)]
          (command-registry.dispatch
            "/goal start --max-iterations 3 -- --max-iterations 20 work"
            run-state)
          (assert.are.equal 3 goal._state.max-iterations)
          (assert.are.equal "--max-iterations 20 work" goal._state.objective))))

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
            (assert.is_truthy (string.find text "GOAL_STATUS: continue" 1 true))
            (assert.is_truthy
              (string.find text "autonomous continuation never grants permission" 1 true)))
          (assert.are.equal :reject (. submitted 1 :opts :when-busy))
          (assert.is_false (. submitted 1 :opts :emit-user?)))))

    (it "shows and applies the conservative default iteration cap"
      (fn []
        (let [(seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal inspect the change" run-state)
          (assert.are.equal 3 goal._state.max-iterations)
          (assert.is_truthy (string.find (. submitted 1 :text) "Iteration: 1 of 3" 1 true))
          (let [decision (last-goal-decision seen)]
            (assert.are.equal :start decision.decision)
            (assert.are.equal 3 decision.max-iterations)))))

    (it "continues until done when the model emits GOAL_STATUS markers"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (assert.are.equal 1 (length submitted))
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Made progress.\nGOAL_STATUS: continue"})
          (assert.are.equal :running goal._state.status)
          (assert.are.equal 2 goal._state.iteration-count)
          (assert.are.equal 2 (length submitted))
          (let [decision (last-goal-decision _seen)]
            (assert.are.equal :continue decision.decision)
            (assert.are.equal :running decision.status)
            (assert.are.equal 2 decision.iteration))
          (assert.is_truthy (string.find (. submitted 2 :text) "Previous iteration result:" 1 true))
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Done.\nGOAL_STATUS: done"})
          (assert.are.equal :done goal._state.status)
          (assert.are.equal "done" goal._state.last-marker)
          (assert.are.equal 2 (length submitted)))))

    (it "ignores a duplicate completion from the previous goal iteration"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (let [iteration-one {:type :agent-turn-complete
                               :agent run-state.agent
                               :turn-id goal._state.active-turn-id
                               :status :ok
                               :result "Made progress.\nGOAL_STATUS: continue"}]
            (events.emit iteration-one)
            (assert.are.equal 2 goal._state.iteration-count)
            (assert.are.equal 2 (length submitted))
            ;; Iteration two is now active; replaying iteration one's completion
            ;; must neither advance the state nor submit a third turn.
            (events.emit iteration-one)
            (assert.are.equal :running goal._state.status)
            (assert.are.equal 2 goal._state.iteration-count)
            (assert.are.equal 2 (length submitted))))))

    (it "fails closed when a submitted turn has no correlation id"
      (fn []
        (let [(_seen _submitted goal _api run-state) (fresh)]
          (set run-state.turn-id nil)
          (set run-state.submit-user-turn!
               (fn [_text _opts] {:ok true :started? true}))
          (command-registry.dispatch "/goal implement feature" run-state)
          (assert.are.equal :error goal._state.status)
          (assert.are.equal "submitted turn has no correlation id" goal._state.last-error)
          (assert.is_true run-state.cancel-requested?)
          (assert.is_nil goal._state.active-turn-id))))

    (it "requires agent compaction before high-context goal work continues"
      (fn []
        (let [(_seen submitted goal api run-state) (fresh)]
          (install-compact-tool! api)
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (set-context-estimate! run-state 90000)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Need more.\nGOAL_STATUS: continue"})
          (assert.are.equal :running goal._state.status)
          (assert.is_true goal._state.compaction-required?)
          (assert.are.equal 2 (length submitted))
          (assert.is_truthy
            (string.find (. submitted 2 :text) "Before doing any other work, call the compact tool" 1 true))
          (events.emit {:type :compaction-summary
                        :agent run-state.agent
                        :trigger :agent
                        :summary "preserved goal"
                        :tokens-before 90000
                        :tokens-after 21000})
          (assert.is_false goal._state.compaction-required?)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Done.\nGOAL_STATUS: done"})
          (assert.are.equal :done goal._state.status)
          (assert.are.equal 21000 goal._state.last-compaction.tokens-after))))

    (it "blocks high-context continuation when compact is unavailable"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (set-context-estimate! run-state 90000)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
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
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Need more.\nGOAL_STATUS: continue"})
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Skipped it.\nGOAL_STATUS: continue"})
          (assert.are.equal :blocked goal._state.status)
          (assert.is_truthy (string.find goal._state.last-reason "required compaction did not complete" 1 true))
          (events.emit {:type :compaction-summary
                        :agent run-state.agent
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

    (it "retries the same iteration after a provider context-limit failure"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (events.emit {:type :error :error "maximum context length exceeded"})
          (assert.are.equal :running goal._state.status)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :error
                        :error "maximum context length exceeded"})
          (assert.are.equal :blocked goal._state.status)
          (assert.is_true goal._state.retry-iteration?)
          (assert.is_truthy (string.find goal._state.last-reason "provider context limit" 1 true))
          (command-registry.dispatch "/goal resume" run-state)
          (assert.are.equal :running goal._state.status)
          (assert.are.equal 1 goal._state.iteration-count)
          (assert.are.equal 2 (length submitted)))))

    (it "allows context-limit recovery at the iteration cap"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 1 implement feature" run-state)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :error
                        :error "maximum context length exceeded"})
          (assert.are.equal :blocked goal._state.status)
          (command-registry.dispatch "/goal resume" run-state)
          (assert.are.equal :running goal._state.status)
          (assert.are.equal 1 goal._state.iteration-count)
          (assert.are.equal 2 (length submitted)))))

    (it "ignores lifecycle and compaction events without the active agent"
      (fn []
        (let [(_seen submitted goal api run-state) (fresh)]
          (install-compact-tool! api)
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (set-context-estimate! run-state 90000)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Need more.\nGOAL_STATUS: continue"})
          (assert.is_true goal._state.compaction-required?)
          (events.emit {:type :compaction-summary
                        :trigger :agent
                        :tokens-before 90000
                        :tokens-after 20000})
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent {:messages []}
                        :status :ok
                        :result "Done.\nGOAL_STATUS: done"})
          (assert.is_true goal._state.compaction-required?)
          (assert.are.equal :running goal._state.status)
          (assert.are.equal 2 (length submitted)))))

    (it "records distinct blocked and error model transitions"
      (fn []
        (let [(blocked-seen _submitted blocked-goal _api blocked-state) (fresh)]
          (command-registry.dispatch "/goal investigate blocker" blocked-state)
          (emit-turn-complete! blocked-goal {:type :agent-turn-complete
                        :agent blocked-state.agent
                        :status :ok
                        :result "Need user input.\nGOAL_STATUS: blocked"})
          (assert.are.equal :blocked blocked-goal._state.status)
          (assert.are.equal :blocked (. (last-goal-decision blocked-seen) :status)))
        (let [(error-seen _submitted error-goal _api error-state) (fresh)]
          (command-registry.dispatch "/goal investigate failure" error-state)
          (emit-turn-complete! error-goal {:type :agent-turn-complete
                        :agent error-state.agent
                        :status :ok
                        :result "Unexpected failure.\nGOAL_STATUS: error"})
          (assert.are.equal :error error-goal._state.status)
          (assert.are.equal :error (. (last-goal-decision error-seen) :status)))))

    (it "stops at the iteration cap instead of running unbounded"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 1 implement feature" run-state)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Need more.\nGOAL_STATUS: continue"})
          (assert.are.equal :cap-reached goal._state.status)
          (assert.are.equal 1 goal._state.iteration-count)
          (assert.are.equal 1 (length submitted))
          (let [decision (last-goal-decision _seen)]
            (assert.are.equal :stop decision.decision)
            (assert.are.equal :cap-reached decision.status)
            (assert.are.equal "iteration cap reached" decision.reason)))))

    (it "blocks when the status marker is missing"
      (fn []
        (let [(_seen _submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal implement feature" run-state)
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "I forgot the marker"})
          (assert.are.equal :blocked goal._state.status)
          (assert.are.equal "missing GOAL_STATUS marker" goal._state.last-reason))))

    (it "rejects immediate resume while the stopped turn is still busy"
      (fn []
        (let [(seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal implement feature" run-state)
          (set run-state.busy? true)
          (command-registry.dispatch "/goal stop" run-state)
          (command-registry.dispatch "/goal resume" run-state)
          (assert.are.equal :stopped goal._state.status)
          (assert.are.equal 1 (length submitted))
          (assert.is_truthy (string.find (. (last-event seen :error) :error)
                                         "turn is in progress" 1 true)))))

    (it "/goal stop prevents future automatic continuation"
      (fn []
        (let [(_seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (command-registry.dispatch "/goal stop" run-state)
          (assert.are.equal :stopped goal._state.status)
          (let [decision (last-goal-decision _seen)]
            (assert.are.equal :stop decision.decision)
            (assert.are.equal :stopped decision.status)
            (assert.are.equal "stopped by user" decision.reason))
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :ok
                        :result "Would continue.\nGOAL_STATUS: continue"})
          (assert.are.equal :stopped goal._state.status)
          (assert.are.equal 1 (length submitted)))))

    (it "/goal stop cooperatively cancels an active goal turn"
      (fn []
        (let [(seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal --max-iterations 3 implement feature" run-state)
          (set run-state.busy? true)
          (set run-state.cancel-requested? false)
          (command-registry.dispatch "/goal stop" run-state)
          (assert.is_true run-state.cancel-requested?)
          (assert.are.equal :stopped goal._state.status)
          (assert.are.equal 1 (length submitted))
          (assert.is_truthy
            (string.find (. (last-goal-decision seen) :text)
                         "active goal turn cancellation requested" 1 true))
          ;; The authoritative completion arrives later, but cannot revive the run.
          (emit-turn-complete! goal {:type :agent-turn-complete
                        :agent run-state.agent
                        :status :cancelled
                        :result "[cancelled]"})
          (assert.are.equal :stopped goal._state.status)
          (assert.are.equal 1 (length submitted)))))    (it "persists authoritative transitions and restores stopped goals without reviving"
      (fn []
        (let [session {:id "session-a" :entries []}]
          (let [(_seen _submitted goal _api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (command-registry.dispatch "/goal --max-iterations 3 durable work" run-state)
            (command-registry.dispatch "/goal stop" run-state)
            (assert.are.equal 2 (length session.entries))
            (assert.are.equal :running (. session.entries 1 :state :status))
            (assert.are.equal :stopped (. session.entries 2 :state :status))
            (assert.are.equal 1 (. session.entries 2 :version))
            (assert.are.equal :stopped goal._state.status))
          (let [(_seen submitted restored _api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (assert.are.equal :stopped restored._state.status)
            (assert.are.equal "durable work" restored._state.objective)
            (assert.are.equal 0 (length submitted))))))

    (it "restores manual compaction recovery before resuming a blocked goal"
      (fn []
        (let [session {:id "session-a"
                       :entries [{:version 1
                                  :state {:status :blocked
                                          :objective "recover me"
                                          :iteration-count 2
                                          :max-iterations 4
                                          :compaction-required? true
                                          :retry-iteration? true}}]}]
          (let [(_seen submitted goal _api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (assert.is_true goal._state.compaction-required?)
            (events.emit {:type :compaction-summary
                          :agent run-state.agent
                          :trigger :manual
                          :tokens-before 90000
                          :tokens-after 20000})
            (assert.is_false goal._state.compaction-required?)
            (command-registry.dispatch "/goal resume" run-state)
            (assert.are.equal :running goal._state.status)
            (assert.are.equal 2 goal._state.iteration-count)
            (assert.are.equal 1 (length submitted))))))

    (it "restores interrupted running goals as explicit same-iteration resumes"
      (fn []
        (let [session {:id "session-a"
                       :entries [{:version 1
                                  :state {:status :running
                                          :objective "resume me"
                                          :iteration-count 2
                                          :max-iterations 4
                                          :last-result "progress"
                                          :active-turn-id "dead-runtime-turn"
                                          :retry-iteration? false}}]}]
          (let [(seen submitted goal _api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (assert.are.equal :blocked goal._state.status)
            (assert.is_nil goal._state.active-turn-id)
            (assert.is_true goal._state.retry-iteration?)
            (assert.is_truthy
              (string.find (. (last-event seen :info) :text)
                           "restored interrupted goal as blocked" 1 true))
            (assert.are.equal 0 (length submitted))
            (command-registry.dispatch "/goal resume" run-state)
            (assert.are.equal :running goal._state.status)
            (assert.are.equal 2 goal._state.iteration-count)
            (assert.are.equal 1 (length submitted))
            (assert.are.equal :running (. session.entries 2 :state :status))))))

    (it "isolates restored state across new and resumed sessions"
      (fn []
        (let [old-entry {:version 1
                         :state {:status :stopped
                                 :objective "old goal"
                                 :iteration-count 1
                                 :max-iterations 3}}
              session {:id "old" :entries []}]
          (table.insert session.entries old-entry)
          (let [(_seen _submitted goal _api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (assert.are.equal "old goal" goal._state.objective)
            (set session.id "new")
            (set session.entries [])
            (events.emit {:type :reset-conversation})
            (assert.are.equal :idle goal._state.status)
            (assert.is_nil goal._state.objective)
            (set session.id "old")
            (set session.entries [old-entry])
            (events.emit {:type :reset-conversation})
            (assert.are.equal :stopped goal._state.status)
            (assert.are.equal "old goal" goal._state.objective)))))

    (it "restores the preceding valid goal when the latest payload is malformed"
      (fn []
        (let [session {:id "fallback"
                       :entries [{:version 1
                                  :state {:status :stopped
                                          :objective "valid goal"
                                          :iteration-count 1
                                          :max-iterations 3}}
                                 {:version 1
                                  :state {:status :blocked
                                          :objective "malformed control state"
                                          :iteration-count 3
                                          :max-iterations 3
                                          :retry-iteration? "false"}}]}]
          (let [(seen _submitted goal _api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (assert.are.equal :stopped goal._state.status)
            (assert.are.equal "valid goal" goal._state.objective)
            (assert.is_truthy
              (string.find (. (last-event seen :info) :text)
                           "restored stopped goal" 1 true))))))

    (it "reports an already-blocked goal without calling it interrupted"
      (fn []
        (let [session {:id "blocked"
                       :entries [{:version 1
                                  :state {:status :blocked
                                          :objective "needs input"
                                          :iteration-count 1
                                          :max-iterations 3
                                          :retry-iteration? false}}]}]
          (let [(seen _submitted goal _api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (let [text (. (last-event seen :info) :text)]
              (assert.is_truthy (string.find text "restored blocked goal" 1 true))
              (assert.is_falsy (string.find text "interrupted" 1 true)))))))

    (it "ignores persisted goal state from a newer incompatible version"
      (fn []
        (let [session {:id "future"
                       :entries [{:version 2
                                  :state {:status :stopped
                                          :objective "future goal"
                                          :iteration-count 1
                                          :max-iterations 3}}]}]
          (let [(seen _submitted goal _api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (assert.are.equal :idle goal._state.status)
            (assert.is_nil goal._state.objective)
            (assert.is_truthy (string.find (. (last-event seen :error) :error)
                                           "incompatible" 1 true))))))

    (it "ignores malformed goal payloads and preserves state across behavior reload"
      (fn []
        (let [bad-session {:id "bad" :entries [{:version 1 :state {:status :running}}]}
              bad-result-session {:id "bad-result"
                                  :entries [{:version 1
                                             :state {:status :blocked
                                                     :objective "bad result"
                                                     :iteration-count 1
                                                     :max-iterations 3
                                                     :last-result {:not :text}}}]}]
          (let [(seen _submitted goal _api run-state) (fresh bad-session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (assert.are.equal :idle goal._state.status)
            (assert.is_truthy (string.find (. (last-event seen :error) :error)
                                           "malformed persisted" 1 true)))
          (let [(seen _submitted goal _api run-state) (fresh bad-result-session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (assert.are.equal :idle goal._state.status)
            (assert.is_truthy (string.find (. (last-event seen :error) :error)
                                           "malformed persisted" 1 true))))
        (let [session {:id "reload" :entries []}]
          (let [(_seen _submitted goal api run-state) (fresh session)]
            (events.emit {:type :agent-started :agent run-state.agent})
            (command-registry.dispatch "/goal reload-safe" run-state)
            (let [state-before goal._state]
              (register-registry.unregister-by-owner :goal)
              (tset package.loaded :fen.extensions.goal nil)
              (let [reloaded (require :fen.extensions.goal)]
                (reloaded.register api)
                (assert.are.equal state-before reloaded._state)
                (assert.are.equal :running reloaded._state.status)
                (assert.are.equal "reload-safe" reloaded._state.objective)))))))

    (it "rejects resume for completed goals"
      (fn []
        (let [(seen submitted goal _api run-state) (fresh)]
          (command-registry.dispatch "/goal implement feature" run-state)
          (emit-turn-complete! goal {:type :agent-turn-complete
                                     :agent run-state.agent
                                     :status :ok
                                     :result "Done.\nGOAL_STATUS: done"})
          (command-registry.dispatch "/goal resume" run-state)
          (assert.are.equal :done goal._state.status)
          (assert.are.equal 1 (length submitted))
          (assert.is_truthy (string.find (. (last-event seen :error) :error)
                                         "not resumable" 1 true)))))
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
