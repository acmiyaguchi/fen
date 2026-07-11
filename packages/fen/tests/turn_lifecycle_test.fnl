(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local turn-lifecycle (require :fen.turn_lifecycle))

(describe "turn lifecycle events"
  (fn []
    (before_each (fn [] (test-api.reset!)))

    (it "builds an ok completion event with result and message count"
      (fn []
        (let [agent {:messages [{:role :user} {:role :assistant}]}
              ev (turn-lifecycle.complete-event {:agent agent} true "done")]
          (assert.are.equal :agent-turn-complete ev.type)
          (assert.are.equal agent ev.agent)
          (assert.is_nil ev.turn-id)
          (assert.are.equal :ok ev.status)
          (assert.are.equal "done" ev.result)
          (assert.are.equal 2 ev.message-count))))

    (it "includes the submitted turn correlation id when available"
      (fn []
        (let [ev (turn-lifecycle.complete-event {:agent {:messages []} :turn-id 7} true "done")]
          (assert.are.equal 7 ev.turn-id))))

    (it "marks aborted turns as cancelled"
      (fn []
        (let [agent {:messages [{:role :assistant :stop-reason :aborted}]}
              ev (turn-lifecycle.complete-event {:agent agent} true "[cancelled]")]
          (assert.are.equal :cancelled ev.status)
          (assert.are.equal "[cancelled]" ev.result)
          (assert.are.equal 1 ev.message-count))))

    (it "summarizes raised error completions"
      (fn []
        (let [agent {:messages []}
              ev (turn-lifecycle.complete-event {:agent agent} false "boom\ntrace")]
          (assert.are.equal :error ev.status)
          (assert.are.equal "boom" ev.error)
          (assert.is_nil ev.result)
          (assert.are.equal 0 ev.message-count))))

    (it "marks provider error messages as error completions"
      (fn []
        (let [agent {:messages [{:role :assistant
                                 :stop-reason :error
                                 :error-message "context overflow\nextra"}]}
              ev (turn-lifecycle.complete-event {:agent agent} true "[error] context overflow")]
          (assert.are.equal :error ev.status)
          (assert.are.equal "context overflow" ev.error)
          (assert.is_nil ev.result)
          (assert.are.equal 1 ev.message-count))))

    (it "emits the completion event through the bus"
      (fn []
        (let [seen []
              agent {:messages [{:role :assistant}]}
              _unsub (events.on :agent-turn-complete
                                (fn [ev] (table.insert seen ev))
                                :turn-lifecycle-test)
              ev (turn-lifecycle.emit-complete! {:agent agent} true "ok")]
          (assert.are.equal 1 (length seen))
          (assert.are.equal ev (. seen 1))
          (assert.are.equal :ok (. seen 1 :status)))))))
