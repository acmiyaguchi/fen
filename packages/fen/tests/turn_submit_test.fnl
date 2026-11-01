(local turn-submit (require :fen.turn_submit))

(fn make-state [?busy ?mailbox]
  {:agent {:seen []}
   :mailbox? ?mailbox
   :busy? (or ?busy false)
   :turn-id 0
   :turn nil
   :turn-result :old
   :turn-error :old-error
   :cancel-requested? true})

(fn agent-step [agent text cancelled?]
  (table.insert agent.seen {:text text :cancelled? (cancelled?)}))

(fn make-emit [events]
  (fn [ev] (table.insert events ev)))

;; Busy-time queueing goes to the core turn mailbox; each queueing test opens
;; a mailbox turn so steering has a running turn to attach to.
(local tasks (require :fen.core.tasks))

(fn with-steering-stub [f]
  (tasks.reset!)
  (tasks.turn-start!)
  (let [(ok? err) (pcall f)]
    (let [snap (tasks.snapshot)]
      (tasks.reset!)
      (when (not ok?) (error err))
      snap)))

(describe "fen.turn_submit"
          (fn []
            (it "rejects empty text"
                (fn []
                  (let [events []
                        st (make-state)
                        result (turn-submit.submit! st "" {} agent-step
                                                    (make-emit events))]
                    (assert.is_false result.ok)
                    (assert.are.equal "cannot submit an empty user turn"
                                      result.error)
                    (assert.is_false st.busy?))))
            (it "rejects invalid busy mode"
                (fn []
                  (let [events []
                        st (make-state true)
                        result (turn-submit.submit! st "work"
                                                    {:when-busy :queue}
                                                    agent-step
                                                    (make-emit events))]
                    (assert.is_false result.ok)
                    (assert.are.equal "invalid when-busy mode: queue"
                                      result.error)
                    (assert.are.equal 0 (length events)))))
            (it "starts an idle user turn"
                (fn []
                  (let [events []
                        st (make-state)
                        result (turn-submit.submit! st "work" {} agent-step
                                                    (make-emit events))]
                    (assert.is_true result.ok)
                    (assert.is_true result.started)
                    (assert.are.equal 1 result.turn-id)
                    (assert.are.equal 1 st.turn-id)
                    (assert.is_true st.busy?)
                    (assert.is_not_nil st.turn)
                    (assert.is_nil st.turn-result)
                    (assert.is_nil st.turn-error)
                    (assert.is_false st.cancel-requested?)
                    (let [(ok? err) (coroutine.resume st.turn)]
                      (assert.is_true ok? err))
                    (assert.are.equal "work" (. st.agent.seen 1 :text))
                    (assert.is_false (. st.agent.seen 1 :cancelled?))
                    (assert.are.equal 0 (length events)))))
            (it "can echo extension-submitted text before starting"
                (fn []
                  (let [events []
                        st (make-state)
                        result (turn-submit.submit! st "approved"
                                                    {:emit-user? true}
                                                    agent-step
                                                    (make-emit events))]
                    (assert.is_true result.ok)
                    (assert.are.equal :user (. events 1 :type))
                    (assert.are.equal "approved" (. events 1 :text))
                    (assert.are.equal 1 (length events)))))
            (it "rejects busy turns by default"
                (fn []
                  (let [events []
                        st (make-state true)
                        result (turn-submit.submit! st "work" {} agent-step
                                                    (make-emit events))]
                    (assert.is_false result.ok)
                    (assert.are.equal "agent is busy" result.error)
                    (assert.are.equal 0 (length events)))))
            (it "refuses queue modes for a busy state without the turn mailbox"
                (fn []
                  (each [_ mode (ipairs [:steering :follow-up])]
                    (let [st (make-state true)
                          result (turn-submit.submit! st "side"
                                                      {:when-busy mode}
                                                      agent-step (make-emit []))]
                      (assert.is_false result.ok)
                      (assert.are.equal "agent is busy and has no input queue"
                                        result.error)))))
            (it "busy main state with no mailbox turn queues steering as a follow-up"
                (fn []
                  (tasks.reset!)
                  (let [st (make-state true true)
                        result (turn-submit.submit! st "during reload"
                                                    {:when-busy :steering}
                                                    agent-step (make-emit []))]
                    (assert.is_true result.ok)
                    (assert.are.equal :follow-up result.queue)
                    (tasks.reset!))))
            (it "a turn that raises still closes its mailbox turn and hands steering back"
                (fn []
                  (tasks.reset!)
                  (let [st (make-state false true)]
                    (turn-submit.start! st "go"
                                        (fn []
                                          (tasks.queue! :steering "unread")
                                          (error "kaboom")))
                    (let [(ok? err) (coroutine.resume st.turn)]
                      (assert.is_false ok?)
                      (assert.is_truthy (string.find (tostring err) "kaboom" 1
                                                     true))
                      (assert.is_truthy (string.find (tostring err) "traceback"
                                                     1 true)
                                        "the crash site's traceback is kept"))
                    (assert.is_false (. (tasks.snapshot) :running?))
                    (assert.are.same [] (. (tasks.snapshot) :steering))
                    (tasks.reset!))))
            (it "queues steering in the turn mailbox while busy"
                (fn []
                  (with-steering-stub (fn []
                                        (let [events []
                                              st (make-state true true)
                                              result (turn-submit.submit! st
                                                                          "steer"
                                                                          {:when-busy :steering}
                                                                          agent-step
                                                                          (make-emit events))]
                                          (assert.is_true result.ok)
                                          (assert.is_true result.queued)
                                          (assert.are.equal :steering
                                                            result.queue)
                                          (assert.are.same ["steer"]
                                                           (. (tasks.snapshot)
                                                              :steering))
                                          (assert.is_nil st.turn
                                                         "queueing must not start a turn")
                                          (assert.are.equal 0 (length events)))))))
            (it "queues follow-up in the turn mailbox while busy"
                (fn []
                  (with-steering-stub (fn []
                                        (let [events []
                                              st (make-state true true)
                                              result (turn-submit.submit! st
                                                                          "after"
                                                                          {:when-busy :follow-up}
                                                                          agent-step
                                                                          (make-emit events))]
                                          (assert.is_true result.ok)
                                          (assert.is_true result.queued)
                                          (assert.are.equal :follow-up
                                                            result.queue)
                                          (assert.are.same ["after"]
                                                           (. (tasks.snapshot)
                                                              :follow-up)))))))))
