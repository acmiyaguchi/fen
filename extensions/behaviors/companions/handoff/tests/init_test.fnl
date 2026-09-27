(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local types (require :fen.core.types))
(local steering-state (require :fen.extensions.steering.state))
(local session-registry (require :fen.core.extensions.register.session_backend))

(fn seed-queues! []
  (while (> (length steering-state.steering-queue) 0)
    (table.remove steering-state.steering-queue))
  (while (> (length steering-state.follow-up-queue) 0)
    (table.remove steering-state.follow-up-queue))
  (table.insert steering-state.steering-queue "queued steering")
  (table.insert steering-state.follow-up-queue "queued follow-up"))

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
    (values seen api)))

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
          (seed-queues!)
          (command-registry.dispatch "/handoff extra guidance" state)
          (let [(ok1? err1) (coroutine.resume state.turn)]
            (assert.is_true ok1? err1))
          (let [(ok2? err2) (coroutine.resume state.turn)]
            (assert.is_true ok2? err2))
          (assert.are.equal :dead (coroutine.status state.turn))
          (assert.are.equal "new-model" state.agent.model)
          (assert.are.equal 1 (length state.agent.messages))
          (assert.is_not_nil (string.find (. state.agent.messages 1 :content) "summary text" 1 true))
          (assert.are.equal 0 (length steering-state.steering-queue))
          (assert.are.equal 0 (length steering-state.follow-up-queue))
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

    (it "keeps the new session handle available for goal-state persistence"
      (fn []
        (let [(seen api) (fresh
                           (fn [_agent _messages _model _opts _on-event yield-fn]
                             (yield-fn)
                             (make-assistant "summary text")))
              state (make-state)
              persisted []]
          (api.register :session-backend
            {:name :memory
             :open (fn [] nil)
             :open-existing (fn [] nil)
             :append (fn [] nil)
             :append-entry (fn [session entry]
                             (table.insert persisted {:session session :entry entry})
                             entry)
             :latest-extension-state (fn [] nil)
             :close (fn [] nil)
             :load (fn [] [])
             :find (fn [] nil)
             :list (fn [] [])
             :latest (fn [] nil)})
          (session-registry.set-active! :memory)
          (session-registry.set-info! {:id :old} state.session)
          (command-registry.dispatch "/handoff" state)
          (assert.is_true (coroutine.resume state.turn))
          (assert.is_true (coroutine.resume state.turn))
          (let [goal-api (test-api.make-runtime-api :goal)]
            (goal-api.session.append-state! {:status :running} 1))
          (assert.are.equal 1 (length persisted))
          (assert.are.equal :new (. persisted 1 :session :id))
          (assert.are.equal :goal (. persisted 1 :entry :extension)))))

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

;; ---------------------------------------------------------------------------
;; Topic-shift suggestion through a mocked decide service (#513)
;; ---------------------------------------------------------------------------

(local input-pipeline (require :fen.core.extensions.input))
(local hint-state (require :fen.extensions.handoff.state))
(local original-decide (. package.loaded :fen.extensions.decide.service))

(fn mock-decide [?enabled?]
  "Decide stub that records ask-async! calls; tests answer them by hand to
   control when (and in what order) the callbacks land."
  (let [calls []]
    (values {:enabled? (fn [] (not= ?enabled? false))
             :ask-async! (fn [st questions on-done]
                           (table.insert calls {:state st :questions questions
                                                :on-done on-done}))}
            calls)))

(fn fresh-with-decide [decide]
  (tset package.loaded :fen.extensions.decide.service decide)
  (set hint-state.pending nil)
  (fresh (fn [] (error "no summary expected"))))

(fn history [n-prompts]
  (let [msgs []]
    (for [i 1 n-prompts]
      (table.insert msgs (types.user-message (.. "fix the parser bug part " i)))
      (table.insert msgs (make-assistant (.. "patched parser step " i))))
    msgs))

(fn submit [text ?opts]
  (let [opts (or ?opts {})]
    (input-pipeline.handle {:kind :user-input :text text}
                           {:busy? (not (not opts.busy?))
                            :state {:agent {:messages (or opts.messages (history 2))}}})))

(fn answer! [call p]
  (call.on-done (when p {:topic_shift {:type :noul :noul p}})))

(describe "extensions.handoff topic-shift suggestion"
  (fn []
    (after_each
      (fn []
        (restore-modules!)
        (tset package.loaded :fen.extensions.decide.service original-decide)))

    (it "suggests /handoff through a :hint event when a shift is likely"
      (fn []
        (let [(decide calls) (mock-decide)
              seen (fresh-with-decide decide)
              action (submit "what's a good sourdough starter ratio?")]
          ;; The prompt is never held or changed while decide runs.
          (assert.are.equal :continue action.action)
          (assert.are.equal "what's a good sourdough starter ratio?" action.input.text)
          (assert.are.equal 1 (length calls))
          (let [st (. calls 1 :state)]
            (assert.are.equal "what's a good sourdough starter ratio?" st.new_message)
            (assert.are.same [{:role :user :text "fix the parser bug part 1"}
                              {:role :assistant :text "patched parser step 1"}
                              {:role :user :text "fix the parser bug part 2"}
                              {:role :assistant :text "patched parser step 2"}]
                             st.recent)
            (assert.are.equal :noul (. calls 1 :questions :topic_shift :type)))
          (assert.are.equal 0 (event-count seen :hint))
          (answer! (. calls 1) 0.9)
          (assert.are.equal 1 (event-count seen :hint))
          (let [hint (last-event seen :hint)]
            (assert.are.equal "topic changed · /handoff" hint.text)
            (assert.are.equal "handoff/topic-shift:what's a good sourdough starter ratio?"
                              hint.key)))))

    (it "stays quiet below the threshold or when decide has no answer"
      (fn []
        (let [(decide calls) (mock-decide)
              seen (fresh-with-decide decide)]
          (submit "keep going on the parser")
          (answer! (. calls 1) 0.84)
          (submit "and the lexer too")
          (answer! (. calls 2) nil)
          (assert.are.equal 2 (length calls))
          (assert.are.equal 0 (event-count seen :hint)))))

    (it "asks nothing while decide is disabled"
      (fn []
        (let [(decide calls) (mock-decide false)
              seen (fresh-with-decide decide)
              action (submit "something else entirely")]
          (assert.are.equal :continue action.action)
          (assert.are.equal 0 (length calls))
          (assert.are.equal 0 (event-count seen :hint)))))

    (it "skips the question without two earlier prompts or while a turn is running"
      (fn []
        (let [(decide calls) (mock-decide)
              _seen (fresh-with-decide decide)]
          (submit "new topic" {:messages (history 1)})
          (submit "new topic" {:busy? true})
          (assert.are.equal 0 (length calls)))))

    (it "drops a late answer once another message was submitted"
      (fn []
        (let [(decide calls) (mock-decide)
              seen (fresh-with-decide decide)
              emit (. (test-api.make-runtime-api :probe) :emit)]
          (submit "first new topic")
          (submit "second new topic")
          (answer! (. calls 1) 0.99)
          (assert.are.equal 0 (event-count seen :hint))
          (answer! (. calls 2) 0.99)
          (assert.are.equal 1 (event-count seen :hint))
          ;; A slash command is a :user line too, and a reset starts over.
          (submit "third new topic")
          (emit {:type :user :text "/model"})
          (answer! (. calls 3) 0.99)
          (submit "fourth new topic")
          (emit {:type :reset-conversation})
          (answer! (. calls 4) 0.99)
          (assert.are.equal 1 (event-count seen :hint)))))))
