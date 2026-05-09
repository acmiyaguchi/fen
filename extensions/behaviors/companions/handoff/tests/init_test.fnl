(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local types (require :fen.core.types))

(local original-agent-mod (. package.loaded :fen.core.agent))

(fn restore-modules! []
  (tset package.loaded :fen.extensions.handoff nil)
  (tset package.loaded :fen.core.agent original-agent-mod))

(fn event-count [seen type-key]
  (var n 0)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set n (+ n 1))))
  n)

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(fn make-assistant [text]
  (types.assistant-message
    {:api :test
     :provider :test
     :model "test-model"
     :content [(types.text-block text)]
     :usage {:input 11 :output 7 :cache-read 0 :cache-write 0 :total-tokens 18}
     :stop-reason :stop}))

(fn fresh [complete-messages]
  (test-api.reset!)
  (tset package.loaded :fen.extensions.handoff nil)
  (tset package.loaded :fen.core.agent {:complete-messages complete-messages})
  (let [seen []
        api (test-api.make-runtime-api :handoff)
        handoff (require :fen.extensions.handoff)]
    (events.on :* (fn [ev] (table.insert seen ev)) :handoff-test)
    (handoff.register api)
    (values seen)))

(fn make-state []
  (let [appended []
        closed []
        queue-updates {:n 0}
        session-backend {:append (fn [session msg]
                                   (table.insert appended {:session session :msg msg}))}]
    {:opts {:provider :test-provider}
     :on-event (fn [_] nil)
     :agent {:messages [(types.user-message "previous context")]
             :model "old-model"}
     :agent-extra {}
     :session {:id :old}
     :session-backend session-backend
     :make-agent-from-opts (fn [_opts _on-event _extra]
                             {:messages [] :model "new-model"})
     :open-session (fn [_opts] {:id :new})
     :close-session (fn [session] (table.insert closed session))
     :make-flush (fn [_agent _session _last-saved]
                   (fn [] nil))
     :session-info (fn [session] {:id session.id})
     :steering-queue ["queued steering"]
     :follow-up-queue ["queued follow-up"]
     :update-queue-status (fn [] (set queue-updates.n (+ queue-updates.n 1)))
     :busy? false
     :turn nil
     :cancel-requested? false
     :_test {:appended appended :closed closed :queue-updates queue-updates}}))

(describe "extensions.handoff"
  (fn []
    (after_each restore-modules!)

    (it "/handoff schedules cooperative work instead of blocking dispatch"
      (fn []
        (let [completed {:value false}
              called {:value false}
              seen (fresh
                     (fn [_agent _messages _model _opts _on-event yield-fn]
                       (set called.value true)
                       (assert.is_not_nil yield-fn)
                       (yield-fn)
                       (set completed.value true)
                       (make-assistant "summary text")))
              state (make-state)]
          (command-registry.dispatch "/handoff" state)
          (assert.is_true state.busy?)
          (assert.is_not_nil state.turn)
          (assert.are.equal :suspended (coroutine.status state.turn))
          (assert.is_false called.value)
          (assert.is_false completed.value)
          (assert.are.equal 0 (event-count seen :llm-start))

          (let [(ok? err) (coroutine.resume state.turn)]
            (assert.is_true ok? err))
          (assert.is_true called.value)
          (assert.is_false completed.value)
          (assert.are.equal :suspended (coroutine.status state.turn))
          (assert.are.equal 1 (event-count seen :llm-start))
          (assert.are.equal 0 (event-count seen :llm-end)))))

    (it "completes handoff by resetting the session and seeding the summary"
      (fn []
        (let [seen (fresh
                     (fn [_agent _messages _model _opts _on-event yield-fn]
                       (yield-fn)
                       (make-assistant "summary text")))
              state (make-state)]
          (command-registry.dispatch "/handoff extra guidance" state)
          (let [(ok1? err1) (coroutine.resume state.turn)]
            (assert.is_true ok1? err1))
          (let [(ok2? err2) (coroutine.resume state.turn)]
            (assert.is_true ok2? err2))
          (assert.are.equal :dead (coroutine.status state.turn))
          (assert.are.equal "new-model" state.agent.model)
          (assert.are.equal 1 (length state.agent.messages))
          (assert.is_not_nil (string.find (. state.agent.messages 1 :content) "summary text" 1 true))
          (assert.are.equal 0 (length state.steering-queue))
          (assert.are.equal 0 (length state.follow-up-queue))
          (assert.are.equal 1 (length state._test.closed))
          (assert.are.equal :old (. state._test.closed 1 :id))
          (assert.are.equal 1 (length state._test.appended))
          (assert.are.equal :new (. state._test.appended 1 :session :id))
          (assert.are.equal (. state.agent.messages 1) (. state._test.appended 1 :msg))
          (assert.are.equal 1 (event-count seen :reset-conversation))
          (assert.are.equal 1 (event-count seen :llm-end))
          (let [ended (last-event seen :llm-end)
                user (last-event seen :user)
                asst (last-event seen :assistant-text)]
            (assert.are.equal 11 ended.usage.input)
            (assert.is_not_nil (string.find user.text "Handoff summary" 1 true))
            (assert.is_not_nil (string.find asst.text "✓ Handoff complete" 1 true))
            (assert.is_not_nil (string.find asst.text "summary text" 1 true))))))

    (it "cancels cooperative handoff without resetting the session"
      (fn []
        (let [seen (fresh
                     (fn [_agent _messages _model _opts _on-event yield-fn]
                       (yield-fn)
                       (make-assistant "should not install")))
              state (make-state)]
          (command-registry.dispatch "/handoff" state)
          (let [(ok1? err1) (coroutine.resume state.turn)]
            (assert.is_true ok1? err1))
          (set state.cancel-requested? true)
          (let [(ok2? err2) (coroutine.resume state.turn)]
            (assert.is_true ok2? err2))
          (assert.are.equal :dead (coroutine.status state.turn))
          (assert.are.equal "old-model" state.agent.model)
          (assert.are.equal 0 (length state._test.closed))
          (assert.are.equal 0 (length state._test.appended))
          (assert.are.equal 1 (event-count seen :llm-start))
          (assert.are.equal 1 (event-count seen :llm-end))
          (assert.are.equal 1 (event-count seen :cancelled)))))))
