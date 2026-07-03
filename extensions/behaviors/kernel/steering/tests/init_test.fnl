(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local steering (require :fen.extensions.steering.service))
(local steering-state (require :fen.extensions.steering.state))

(fn reset! []
  (test-api.reset!)
  (while (> (length steering-state.steering-queue) 0)
    (table.remove steering-state.steering-queue))
  (while (> (length steering-state.follow-up-queue) 0)
    (table.remove steering-state.follow-up-queue))
  (set steering-state.steering-mode :one-at-a-time)
  (set steering-state.follow-up-mode :one-at-a-time))

(fn watch [type-key]
  (let [seen []]
    (events.on type-key (fn [ev] (table.insert seen ev)) :steering-test)
    seen))

(describe "fen.extensions.steering"
  (fn []
    (it "submit starts a turn when idle without queueing"
      (fn []
        (reset!)
        (let [result (steering.submit "hello" {:busy? false})]
          (assert.are.equal :start result.action)
          (assert.are.equal "hello" result.text)
          (assert.are.equal 0 (. (steering.queue-info) :steering-queued)))))

    (it "submit queues steering while busy and emits :queued"
      (fn []
        (reset!)
        (let [seen (watch :queued)
              result (steering.submit "steer me" {:busy? true})]
          (assert.are.equal :queued result.action)
          (assert.are.equal :steering result.queue)
          (assert.are.same ["steer me"] steering-state.steering-queue)
          (assert.are.equal :steering (. seen 1 :queue))
          (assert.are.equal "steer me" (. seen 1 :text)))))

    (it "submit strips > prefix into the follow-up queue while busy"
      (fn []
        (reset!)
        (let [result (steering.submit ">  after this turn " {:busy? true})]
          (assert.are.equal :queued result.action)
          (assert.are.equal :follow-up result.queue)
          (assert.are.same ["after this turn"] steering-state.follow-up-queue)
          (assert.are.same [] steering-state.steering-queue))))

    (it "queue! updates status counts on the bus"
      (fn []
        (reset!)
        (let [seen (watch :set-status-info)]
          (steering.queue! :steering "one")
          (steering.queue! :follow-up "two")
          (let [info (. seen (length seen) :info)]
            (assert.are.equal 1 info.steering-queued)
            (assert.are.equal 1 info.follow-up-queued)))))

    (it "queue! rejects unknown kinds"
      (fn []
        (reset!)
        (let [result (steering.queue! :bogus "x")]
          (assert.is_false result.ok)
          (assert.are.equal 0 (. (steering.queue-info) :steering-queued)))))

    (it "get-steering drains one line by default"
      (fn []
        (reset!)
        (steering.queue! :steering "a")
        (steering.queue! :steering "b")
        (assert.are.same ["a"] (steering.get-steering))
        (assert.are.same ["b"] (steering.get-steering))
        (assert.are.same [] (steering.get-steering))))

    (it "get-follow-up drains everything in :all mode"
      (fn []
        (reset!)
        (steering.queue! :follow-up "a")
        (steering.queue! :follow-up "b")
        (assert.is_true (steering.set-queue-mode! :follow-up :all))
        (assert.are.same ["a" "b"] (steering.get-follow-up))
        (assert.are.same [] steering-state.follow-up-queue)))

    (it "set-queue-mode! rejects unknown kinds and modes"
      (fn []
        (reset!)
        (assert.is_false (steering.set-queue-mode! :steering :sometimes))
        (assert.is_false (steering.set-queue-mode! :bogus :all))
        (assert.are.equal :one-at-a-time steering-state.steering-mode)))

    (it "clear-queues! clears one queue or both"
      (fn []
        (reset!)
        (steering.queue! :steering "s")
        (steering.queue! :follow-up "f")
        (steering.clear-queues! :steering)
        (assert.are.same [] steering-state.steering-queue)
        (assert.are.same ["f"] steering-state.follow-up-queue)
        (steering.clear-queues!)
        (assert.are.same [] steering-state.follow-up-queue)))

    (it "clear-queues! preserves queue table identity for live captures"
      (fn []
        (reset!)
        (let [captured steering-state.steering-queue]
          (steering.queue! :steering "s")
          (steering.clear-queues!)
          (assert.are.equal captured steering-state.steering-queue))))

    (it "queue-snapshot returns copies, not live queue tables"
      (fn []
        (reset!)
        (steering.queue! :steering "s")
        (let [snap (steering.queue-snapshot)]
          (table.insert snap.steering "mutated")
          (assert.are.same ["s"] steering-state.steering-queue)
          (assert.are.equal :one-at-a-time snap.steering-mode))))

    (it "accepts the :followup spelling used by /queue arguments"
      (fn []
        (reset!)
        (steering.queue! :followup "f")
        (assert.are.same ["f"] steering-state.follow-up-queue)
        (steering.clear-queues! :followup)
        (assert.are.same [] steering-state.follow-up-queue)))

    (it "registers an introspect snapshot of queue depths"
      (fn []
        (reset!)
        (let [entry (require :fen.extensions.steering)
              api (test-api.make-runtime-api :steering)]
          (entry.register api)
          (steering.queue! :steering "s")
          (let [introspect (require :fen.core.extensions.register.introspect)
                snapshots (introspect.collect)]
            (assert.are.equal 1 (. snapshots :steering :queues :steering-queued))))))))
