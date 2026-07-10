(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local types (require :fen.core.types))

(local original-agent-mod (. package.loaded :fen.core.agent))

(fn restore-modules! []
  (tset package.loaded :fen.extensions.compact nil)
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
     :usage {:input 9 :output 5 :cache-read 0 :cache-write 0 :total-tokens 14}
     :stop-reason :stop}))

(fn with-id [msg id]
  (tset msg :__session-entry-id id)
  msg)

(fn fresh [complete-messages]
  (test-api.reset!)
  (tset package.loaded :fen.extensions.compact nil)
  (tset package.loaded :fen.core.agent {:complete-messages complete-messages})
  (let [seen []
        api (test-api.make-runtime-api :compact)
        compact (require :fen.extensions.compact)]
    (events.on :* (fn [ev] (table.insert seen ev)) :compact-test)
    (compact.register api)
    (values seen compact)))

(fn registered-tool [name]
  (var found nil)
  (each [_ tool (ipairs (tool-registry.merged []))]
    (when (= tool.name name)
      (set found tool)))
  found)

(fn first-result-text [result]
  (?. result :content 1 :text))

(fn large-text []
  (string.rep "x" 90000))

(fn make-state []
  (let [entries []
        flushes {:n 0}
        backend {:append-entry (fn [_session entry]
                                 (let [out {}]
                                   (each [k v (pairs entry)]
                                     (tset out k v))
                                   (set out.id (or out.id (.. "comp-" (+ (length entries) 1))))
                                   (table.insert entries out)
                                   out))}
        messages [(with-id (types.user-message (large-text)) "m1")
                  (with-id (types.assistant-message
                             {:api :test :provider :test :model "m"
                              :content [(types.text-block (large-text))]
                              :stop-reason :stop}) "m2")
                  (with-id (types.user-message "recent user") "m3")
                  (with-id (types.assistant-message
                             {:api :test :provider :test :model "m"
                              :content [(types.text-block "recent assistant")]
                              :stop-reason :stop}) "m4")]]
    {:agent {:messages messages :model "m"}
     :session {:id :s}
     :session-backend backend
     :flush (fn [] (set flushes.n (+ flushes.n 1)))
     :make-flush (fn [_agent _session last-saved]
                   (set flushes.last-saved last-saved)
                   (fn [] nil))
     :busy? false
     :turn nil
     :cancel-requested? false
     :_test {:entries entries :flushes flushes :original messages}}))

(describe "extensions.compact"
  (fn []
    (after_each restore-modules!)

    (it "/compact schedules cooperative work instead of blocking dispatch"
      (fn []
        (let [called {:value false}
              completed {:value false}
              seen (fresh
                     (fn [_agent _messages _model _opts _on-event yield-fn]
                       (set called.value true)
                       (assert.is_not_nil yield-fn)
                       (yield-fn)
                       (set completed.value true)
                       (make-assistant "summary text")))
              state (make-state)]
          (command-registry.dispatch "/compact" state)
          (assert.is_true state.busy?)
          (assert.is_not_nil state.turn)
          (assert.is_false called.value)
          (let [(ok? err) (coroutine.resume state.turn)]
            (assert.is_true ok? err))
          (assert.is_true called.value)
          (assert.is_false completed.value)
          (assert.are.equal :suspended (coroutine.status state.turn))
          (assert.are.equal 1 (event-count seen :llm-start)))))

    (it "compacts older messages, keeps recent messages, and writes a compaction entry"
      (fn []
        (let [seen (fresh
                     (fn [_agent _messages _model _opts _on-event yield-fn]
                       (yield-fn)
                       (make-assistant "summary text")))
              state (make-state)]
          (command-registry.dispatch "/compact focus files" state)
          (let [(ok1? err1) (coroutine.resume state.turn)]
            (assert.is_true ok1? err1))
          (let [(ok2? err2) (coroutine.resume state.turn)]
            (assert.is_true ok2? err2))
          (assert.are.equal :dead (coroutine.status state.turn))
          (assert.are.equal 3 (length state.agent.messages))
          (assert.is_not_nil (string.find (. state.agent.messages 1 :content) "summary text" 1 true))
          (assert.are.equal "recent user" (. state.agent.messages 2 :content))
          (assert.are.equal "recent assistant" (. state.agent.messages 3 :content 1 :text))
          (assert.are.equal 1 (length state._test.entries))
          (let [entry (. state._test.entries 1)]
            (assert.are.equal :compaction entry.type)
            (assert.are.equal "m3" (. entry :first-kept-entry-id))
            (assert.are.equal "focus files" entry.guidance))
          (assert.are.equal 1 state._test.flushes.n)
          (assert.are.equal 3 state._test.flushes.last-saved)
          (assert.are.equal 1 (event-count seen :llm-end))
          (let [done (last-event seen :compaction-summary)]
            (assert.are.equal "summary text" done.summary)
            (assert.are.equal 2 done.messages-summarized)
            (assert.are.equal 2 done.messages-kept)
            (assert.are.equal "focus files" done.guidance)
            (assert.are.equal :manual done.trigger)))))

    (it "registers an agent-callable compact tool that persists compaction"
      (fn []
        (let [seen (fresh
                     (fn [_agent _messages _model _opts _on-event yield-fn]
                       (yield-fn)
                       (make-assistant "tool summary")))
              state (make-state)
              tool (registered-tool :compact)]
          ;; Match the real in-turn shape: the current user request and compact
          ;; ToolCall must survive so core can append the paired ToolResult.
          (table.insert state.agent.messages
                        (with-id (types.user-message "compact before continuing") "m5"))
          (table.insert state.agent.messages
                        (with-id (types.assistant-message
                                   {:api :test :provider :test :model "m"
                                    :content [(types.tool-call-block
                                                "tc1" :compact
                                                {:guidance "preserve goal progress"})]
                                    :stop-reason :tool-use})
                                 "m6"))
          (let [result (tool.execute {:guidance "preserve goal progress"}
                                     {:state state}
                                     (fn [] nil))]
            (assert.is_not_nil tool)
            (assert.is_false result.is-error?)
            (assert.is_truthy (string.find (first-result-text result) "Compacted context" 1 true))
            (assert.are.equal :tool-call (. state.agent.messages 5 :content 1 :type))
            (assert.are.equal "tc1" (. state.agent.messages 5 :content 1 :id))
            (assert.are.equal 1 (length state._test.entries))
            (let [entry (. state._test.entries 1)
                  done (last-event seen :compaction-summary)]
              (assert.are.equal :agent entry.trigger)
              (assert.are.equal "preserve goal progress" entry.guidance)
              (assert.are.equal :agent done.trigger)
              (assert.are.equal "tool summary" done.summary))))))

    (it "does not persist or install a provider-error summary"
      (fn []
        (let [seen (fresh
                     (fn []
                       (types.assistant-message
                         {:api :test :provider :test :model "m"
                          :content [(types.text-block "[error] upstream failed")]
                          :error-message "upstream failed"
                          :stop-reason :error})))
              state (make-state)
              original [(table.unpack state.agent.messages)]
              tool (registered-tool :compact)
              result (tool.execute {} {:state state} (fn [] nil))]
          (assert.is_true result.is-error?)
          (assert.is_truthy (string.find (first-result-text result) "upstream failed" 1 true))
          (assert.are.equal 0 (length state._test.entries))
          (assert.are.equal (length original) (length state.agent.messages))
          (assert.are.equal 1 (event-count seen :llm-start))
          (assert.are.equal 1 (event-count seen :llm-end)))))

    (it "returns a tool error when context cannot be compacted"
      (fn []
        (let [(seen _compact) (fresh (fn [] (make-assistant "unused")))
              state (make-state)
              tool (registered-tool :compact)]
          (set state.agent.messages [(with-id (types.user-message "small") "m1")])
          (let [result (tool.execute {} {:state state} (fn [] nil))]
            (assert.is_true result.is-error?)
            (assert.is_truthy (string.find (first-result-text result) "not enough context" 1 true))
            (assert.are.equal 0 (event-count seen :error))))))

    (it "propagates agent-tool cancellation to the agent loop"
      (fn []
        (let [seen (fresh
                     (fn [_agent _messages _model _opts _on-event yield-fn]
                       (yield-fn)
                       (make-assistant "should not install")))
              state (make-state)
              original [(table.unpack state.agent.messages)]
              tool (registered-tool :compact)
              cancel-marker {:type :test-cancel}
              (ok? err) (pcall tool.execute {} {:state state}
                                (fn [] (error cancel-marker)))]
          (assert.is_false ok?)
          (assert.are.equal cancel-marker err)
          (assert.are.equal (length original) (length state.agent.messages))
          (assert.are.equal 0 (length state._test.entries))
          (assert.are.equal 1 (event-count seen :llm-start))
          (assert.are.equal 1 (event-count seen :llm-end)))))

    (it "cancels without mutating messages or writing entries"
      (fn []
        (let [seen (fresh
                     (fn [_agent _messages _model _opts _on-event yield-fn]
                       (yield-fn)
                       (make-assistant "should not install")))
              state (make-state)
              original [(table.unpack state.agent.messages)]]
          (command-registry.dispatch "/compact" state)
          (let [(ok1? err1) (coroutine.resume state.turn)]
            (assert.is_true ok1? err1))
          (set state.cancel-requested? true)
          (let [(ok2? err2) (coroutine.resume state.turn)]
            (assert.is_true ok2? err2))
          (assert.are.equal :dead (coroutine.status state.turn))
          (assert.are.equal (length original) (length state.agent.messages))
          (each [i msg (ipairs original)]
            (assert.are.equal msg (. state.agent.messages i)))
          (assert.are.equal 0 (length state._test.entries))
          (assert.are.equal 1 (event-count seen :cancelled)))))

    (it "does not call the model when there is not enough context"
      (fn []
        (let [called {:value false}
              seen (fresh
                     (fn [_agent _messages _model _opts _on-event _yield-fn]
                       (set called.value true)
                       (make-assistant "unused")))
              state (make-state)]
          (set state.agent.messages [(with-id (types.user-message "small") "m1")
                                     (with-id (types.assistant-message
                                                {:api :test :provider :test :model "m"
                                                 :content [(types.text-block "small")]
                                                 :stop-reason :stop}) "m2")])
          (command-registry.dispatch "/compact" state)
          (let [(ok? err) (coroutine.resume state.turn)]
            (assert.is_true ok? err))
          (assert.is_false called.value)
          (assert.are.equal 0 state._test.flushes.n)
          (assert.are.equal 0 (length state._test.entries))
          (let [err (last-event seen :error)]
            (assert.is_not_nil (string.find err.error "not enough context" 1 true))))))

    (it "does not flush when the session backend cannot persist compactions"
      (fn []
        (let [called {:value false}
              seen (fresh
                     (fn [_agent _messages _model _opts _on-event _yield-fn]
                       (set called.value true)
                       (make-assistant "unused")))
              state (make-state)]
          (set state.session-backend {})
          (command-registry.dispatch "/compact" state)
          (let [(ok? err) (coroutine.resume state.turn)]
            (assert.is_true ok? err))
          (assert.is_false called.value)
          (assert.are.equal 0 state._test.flushes.n)
          (let [err (last-event seen :error)]
            (assert.is_not_nil (string.find err.error "append%-entry"))))))

    (it "cut finder refuses assistant thinking at the kept boundary"
      (fn []
        (let [(_seen compact) (fresh (fn [] (make-assistant "unused")))
              msgs [(with-id (types.user-message (large-text)) "m1")
                    (with-id (types.assistant-message
                               {:api :test :provider :test :model "m"
                                :content [(types.thinking-block {:thinking (large-text)
                                                                 :thinking-signature "sig"})]
                                :stop-reason :stop}) "m2")]]
          (assert.is_nil (compact._test.find-cut-point msgs 20000)))))))
