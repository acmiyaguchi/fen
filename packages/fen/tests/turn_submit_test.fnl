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
(local hold (require :fen.testing.tasks))

(fn with-steering-stub [f]
  (tasks.reset!)
  ((. (require :fen.testing.tasks) :hold-turn!))
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
                    (assert.is_nil st.cancel-requested?
                                   "a cancel set while idle arms nothing")
                    (let [(ok? err) (coroutine.resume st.turn)]
                      (assert.is_true ok? err))
                    (assert.are.equal "work" (. st.agent.seen 1 :text))
                    (assert.is_false (. st.agent.seen 1 :cancelled?))
                    (assert.are.equal 0 (length events)))))
            (it "plain state: a cancel captured for turn 1 never cancels turn 2"
                (fn []
                  (let [fence (require :fen.util.cancel_fence)
                        st (make-state)
                        checks []
                        step (fn [_agent _text cancelled?]
                               (table.insert checks cancelled?)
                               (coroutine.yield))]
                    (turn-submit.start! st "one" step)
                    (coroutine.resume st.turn)
                    (let [pressed-for (fence.current st)]
                      (set st.busy? false)
                      (turn-submit.start! st "two" step)
                      (coroutine.resume st.turn)
                      ;; Late Ctrl-C for turn 1, then a live one for turn 2.
                      (assert.is_false (fence.cancel! st pressed-for))
                      (assert.is_false ((. checks 2)))
                      (assert.is_true (fence.cancel-current! st))
                      (assert.is_true ((. checks 2)))
                      (assert.is_false ((. checks 1))
                                       "turn 1's stale check sees turn 2's cancel")))))
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
                                          (tasks.offer! "unread")
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

(describe "fen.turn_submit holder"
          (fn []
            (before_each (fn [] (tasks.reset!)))
            (after_each (fn [] (tasks.reset!)))
            (it "starts a main turn in one offer-start step, its coroutine registered as the current job"
                (fn []
                  (let [st (make-state false true)
                        result (turn-submit.start! st "go" agent-step)]
                    (assert.is_true result.ok)
                    (assert.are.equal 1 result.turn)
                    (assert.are.equal :turn (. (tasks.holder) :kind))
                    (assert.are.equal 1 (. (tasks.holder) :n))
                    (assert.are.equal st.turn (. (tasks.current-job) :co))
                    (coroutine.resume st.turn)
                    (assert.are.equal :dead (coroutine.status st.turn))
                    (assert.are.equal :none (. (tasks.holder) :kind)))))
            (it "the typed line starts first; an older leftover follows at a natural stop"
                (fn []
                  (tasks.offer! "older" {:follow-up? true})
                  (let [st (make-state false true)]
                    (turn-submit.start! st "newer" agent-step)
                    (coroutine.resume st.turn)
                    (assert.are.equal "newer" (. st.agent.seen 1 :text))
                    (assert.are.same ["older"] (. (tasks.snapshot) :follow-up)))))
            (it "an idle submit emits no :queued event and one status update"
                (fn []
                  (let [events (require :fen.core.extensions.events)
                        seen []
                        st (make-state false true)]
                    (events.on :* #(table.insert seen $1.type)
                               :idle-submit-test)
                    (turn-submit.submit! st "go" {} agent-step (make-emit []))
                    (events.unregister-by-owner :idle-submit-test)
                    (assert.are.same []
                                     (icollect [_ t (ipairs seen)]
                                       (when (= t :queued) t)))
                    (assert.are.equal 1
                                      (length (icollect [_ t (ipairs seen)]
                                                (when (= t :set-status-info) t)))))))
            (it "a status handler reacting during the start cannot steal the turn or lose the prompt"
                (fn []
                  (let [events (require :fen.core.extensions.events)
                        st (make-state false true)
                        other (make-state false true)
                        stolen []]
                    (events.on :set-status-info
                               (fn [_]
                                 (table.insert stolen
                                               (turn-submit.start! other
                                                                   "thief"
                                                                   agent-step))
                                 (table.insert stolen
                                               (turn-submit.start-queued! other
                                                                          agent-step)))
                               :steal-test)
                    (let [r (turn-submit.start! st "mine" agent-step)]
                      (events.unregister-by-owner :steal-test)
                      (assert.is_true r.ok)
                      (assert.are.equal st.turn (. (tasks.current-job) :co))
                      (assert.is_false (. stolen 1 :ok))
                      (assert.is_nil (. stolen 2))
                      (assert.is_nil other.turn)
                      (coroutine.resume st.turn)
                      (assert.are.equal "mine" (. st.agent.seen 1 :text))))))
            (it "behind an exclusive job the line waits with its own body and starts when the job ends (c)"
                (fn []
                  (let [job (hold.hold-exclusive! (fn [] (coroutine.yield)))
                        st (make-state false true)
                        result (turn-submit.start! st "go"
                                                   (fn [agent text _]
                                                     (table.insert agent.seen
                                                                   {:text text
                                                                    :own? true})))]
                    (assert.is_true result.ok)
                    (assert.is_true result.start-pending?)
                    (assert.is_nil st.turn)
                    ;; a deferred reload requested meanwhile still goes after it
                    (tasks.request-job! {:run (fn [] nil)})
                    (coroutine.resume job)
                    (coroutine.resume job)
                    (let [r (turn-submit.start-queued! st agent-step)]
                      (assert.is_true r.ok)
                      (coroutine.resume st.turn)
                      (assert.are.same [{:text "go" :own? true}] st.agent.seen
                                       "the line's own agent-step ran"))
                    (assert.are.equal 1 (. (tasks.snapshot) :jobs)))))
            (it "start-queued! starts only a requested follow-up"
                (fn []
                  (let [st (make-state false true)]
                    (tasks.offer! "plain" {:follow-up? true})
                    (assert.is_nil (turn-submit.start-queued! st agent-step))
                    (tasks.offer! "asked" {:turn 0})
                    (let [r (turn-submit.start-queued! st agent-step)]
                      (assert.is_true r.ok)
                      (coroutine.resume st.turn)
                      (assert.are.equal "asked" (. st.agent.seen 1 :text)
                                        "the line that asked starts")))))
            (it "cancel! for the running turn reaches the agent's cancel check"
                (fn []
                  (let [st (make-state false true)]
                    (turn-submit.start! st "go" agent-step)
                    (set st.cancel-requested? false)
                    (assert.is_true (tasks.cancel! 1))
                    (coroutine.resume st.turn)
                    (assert.is_true (. st.agent.seen 1 :cancelled?)))))
            (it "abandonment: drop! releases a turn that was never resumed and hands its steering back"
                (fn []
                  (let [st (make-state false true)]
                    (turn-submit.start! st "go" agent-step)
                    (tasks.offer! "unread")
                    (assert.is_nil (tasks.release! 999)
                                   "a stale release is fenced out")
                    (assert.are.same ["unread"] (. (tasks.snapshot) :steering))
                    (turn-submit.drop! st)
                    (assert.are.equal :none (. (tasks.holder) :kind))
                    (assert.are.same [] (. (tasks.snapshot) :steering))
                    (assert.is_nil st.turn)
                    (assert.is_false st.busy?))))
            (it "abandonment: drop! after the body already released is a no-op"
                (fn []
                  (let [st (make-state false true)]
                    (turn-submit.start! st "go" agent-step)
                    (coroutine.resume st.turn)
                    (let [(_ hid) (hold.hold-exclusive!)]
                      (turn-submit.drop! st)
                      (assert.are.equal hid (. (tasks.holder) :hid)
                                        "a newer holder survives the stale drop")))))))
