(local turn-submit (require :fen.turn_submit))

(fn make-state [?busy]
  {:agent {:seen []}
   :busy? (or ?busy false)
   :turn nil
   :turn-result :old
   :turn-error :old-error
   :cancel-requested? true})

(fn agent-step [agent text cancelled?]
  (table.insert agent.seen {:text text :cancelled? (cancelled?)}))

(fn make-emit [events]
  (fn [ev] (table.insert events ev)))

;; turn_submit delegates busy-queueing to the steering extension at call
;; time, so a package.loaded stub observes the delegation without pulling
;; the real queue state into this unit test.
(local original-steering (. package.loaded :fen.extensions.steering.service))

(fn with-steering-stub [f]
  (let [queued []]
    (tset package.loaded :fen.extensions.steering.service
          {:queue! (fn [kind text]
                     (table.insert queued {:kind kind :text text})
                     {:ok true :queued true :queue kind})})
    (let [(ok? err) (pcall f queued)]
      (tset package.loaded :fen.extensions.steering.service original-steering)
      (when (not ok?) (error err)))))

(describe "fen.turn_submit"
  (fn []
    (it "rejects empty text"
      (fn []
        (let [events []
              st (make-state)
              result (turn-submit.submit! st "" {} agent-step (make-emit events))]
          (assert.is_false result.ok)
          (assert.are.equal "cannot submit an empty user turn" result.error)
          (assert.is_false st.busy?))))

    (it "rejects invalid busy mode"
      (fn []
        (let [events []
              st (make-state true)
              result (turn-submit.submit! st "work" {:when-busy :queue}
                                          agent-step (make-emit events))]
          (assert.is_false result.ok)
          (assert.are.equal "invalid when-busy mode: queue" result.error)
          (assert.are.equal 0 (length events)))))

    (it "starts an idle user turn"
      (fn []
        (let [events []
              st (make-state)
              result (turn-submit.submit! st "work" {} agent-step (make-emit events))]
          (assert.is_true result.ok)
          (assert.is_true result.started)
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
              result (turn-submit.submit! st "approved" {:emit-user? true}
                                          agent-step (make-emit events))]
          (assert.is_true result.ok)
          (assert.are.equal :user (. events 1 :type))
          (assert.are.equal "approved" (. events 1 :text))
          (assert.are.equal 1 (length events)))))

    (it "rejects busy turns by default"
      (fn []
        (let [events []
              st (make-state true)
              result (turn-submit.submit! st "work" {} agent-step (make-emit events))]
          (assert.is_false result.ok)
          (assert.are.equal "agent is busy" result.error)
          (assert.are.equal 0 (length events)))))

    (it "queues steering with the steering service while busy"
      (fn []
        (with-steering-stub
          (fn [queued]
            (let [events []
                  st (make-state true)
                  result (turn-submit.submit! st "steer" {:when-busy :steering}
                                              agent-step (make-emit events))]
              (assert.is_true result.ok)
              (assert.is_true result.queued)
              (assert.are.equal :steering result.queue)
              (assert.are.same [{:kind :steering :text "steer"}] queued)
              (assert.is_nil st.turn "queueing must not start a turn")
              (assert.are.equal 0 (length events)))))))

    (it "queues follow-up with the steering service while busy"
      (fn []
        (with-steering-stub
          (fn [queued]
            (let [events []
                  st (make-state true)
                  result (turn-submit.submit! st "after" {:when-busy :follow-up}
                                              agent-step (make-emit events))]
              (assert.is_true result.ok)
              (assert.is_true result.queued)
              (assert.are.equal :follow-up result.queue)
              (assert.are.same [{:kind :follow-up :text "after"}] queued))))))))
