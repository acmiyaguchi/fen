(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local types (require :fen.core.types))

(describe "turn lifecycle events"
          (fn []
            (before_each (fn [] (test-api.reset!)))
            (it "builds an ok completion event with result and message count"
                (fn []
                  (let [agent {:messages [{:role :user} {:role :assistant}]}
                        state {:agent agent}
                        ev (turn-lifecycle.complete-event state true "done")]
                    (assert.are.equal :agent-turn-complete ev.type)
                    (assert.are.equal agent ev.agent)
                    (assert.are.equal state ev.state)
                    (assert.is_nil ev.turn-id)
                    (assert.are.equal :ok ev.status)
                    (assert.are.equal "done" ev.result)
                    (assert.are.equal 2 ev.message-count))))
            (it "includes the submitted turn correlation id when available"
                (fn []
                  (let [ev (turn-lifecycle.complete-event {:agent {:messages []}
                                                           :turn-id 7}
                                                          true "done")]
                    (assert.are.equal 7 ev.turn-id))))
            (it "marks aborted turns as cancelled"
                (fn []
                  (let [agent {:messages [{:role :assistant
                                           :stop-reason :aborted}]}
                        ev (turn-lifecycle.complete-event {:agent agent} true
                                                          "[cancelled]")]
                    (assert.are.equal :cancelled ev.status)
                    (assert.are.equal "[cancelled]" ev.result)
                    (assert.are.equal 1 ev.message-count))))
            (it "summarizes raised error completions"
                (fn []
                  (let [agent {:messages []}
                        ev (turn-lifecycle.complete-event {:agent agent} false
                                                          "boom\ntrace")]
                    (assert.are.equal :error ev.status)
                    (assert.are.equal "boom" ev.error)
                    (assert.is_nil ev.result)
                    (assert.are.equal 0 ev.message-count))))
            (it "reports the Outcome agent.step recorded"
                (fn []
                  (let [agent {:messages [{:role :assistant
                                           :stop-reason :error
                                           :error-message "context overflow\nextra"}]
                               :outcome (types.outcome :error
                                                       "[error] context overflow"
                                                       "context overflow\nextra")}
                        ev (turn-lifecycle.complete-event {:agent agent} true
                                                          "[error] context overflow")]
                    (assert.are.equal :error ev.status)
                    (assert.are.equal agent.outcome ev.outcome)
                    (assert.are.equal "context overflow" ev.error)
                    (assert.is_nil ev.result)
                    (assert.are.equal 1 ev.message-count))))
            (it "does not infer the status from the last message (#609)"
                (fn []
                  (let [agent {:messages [{:role :tool-result
                                           :tool-call-id :c1}]
                               :outcome (types.outcome :error "[error] capped"
                                                       "capped")}
                        ev (turn-lifecycle.complete-event {:agent agent} true
                                                          "[error] capped")]
                    (assert.are.equal :error ev.status)
                    (assert.are.equal "capped" ev.error))
                  (let [agent {:messages [{:role :assistant
                                           :stop-reason :error}]
                               :outcome (types.outcome :ok "fine")}
                        ev (turn-lifecycle.complete-event {:agent agent} true
                                                          "fine")]
                    (assert.are.equal :ok ev.status)
                    (assert.are.equal "fine" ev.result))))
            (it "emits the completion event through the bus"
                (fn []
                  (let [seen []
                        agent {:messages [{:role :assistant}]}
                        _unsub (events.on :agent-turn-complete
                                          (fn [ev] (table.insert seen ev))
                                          :turn-lifecycle-test)
                        ev (turn-lifecycle.emit-complete! {:agent agent} true
                                                          "ok")]
                    (assert.are.equal 1 (length seen))
                    (assert.are.equal ev (. seen 1))
                    (assert.are.equal :ok (. seen 1 :status)))))
            (it "consumes the Outcome so a later non-step turn cannot read it"
                (fn []
                  (let [agent {:messages []
                               :outcome (types.outcome :error nil "x")}]
                    (assert.are.equal :error
                                      (. (turn-lifecycle.emit-complete! {: agent}
                                                                        true nil)
                                         :status))
                    (assert.is_nil agent.outcome)
                    (assert.are.equal :ok
                                      (. (turn-lifecycle.emit-complete! {: agent}
                                                                        true
                                                                        "done")
                                         :status)))))))
