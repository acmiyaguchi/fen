(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local steering (require :fen.extensions.steering.service))
(local tasks (require :fen.core.tasks))

(fn snap [key] (. (tasks.snapshot) key))

(fn reset! []
  "Fresh machine with one running main turn, so steering has a turn to attach to."
  (test-api.reset!)
  (tasks.reset!)
  ;; Held, never resumed: the next reset! drops it.
  (tasks.spawn-holder :turn #(coroutine.yield)))

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
                    (assert.are.equal 0
                                      (. (steering.queue-info) :steering-queued)))))
            (it "submit queues steering while busy and emits :queued"
                (fn []
                  (reset!)
                  (let [seen (watch :queued)
                        result (steering.submit "steer me" {:busy? true})]
                    (assert.are.equal :queued result.action)
                    (assert.are.equal :steering result.queue)
                    (assert.are.same ["steer me"] (snap :steering))
                    (assert.are.equal :steering (. seen 1 :queue))
                    (assert.are.equal "steer me" (. seen 1 :text)))))
            (it "submit strips > prefix into the follow-up queue while busy"
                (fn []
                  (reset!)
                  (let [result (steering.submit ">  after this turn "
                                                {:busy? true})]
                    (assert.are.equal :queued result.action)
                    (assert.are.equal :follow-up result.queue)
                    (assert.are.same ["after this turn"] (snap :follow-up))
                    (assert.are.same [] (snap :steering)))))
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
                    (assert.are.equal 0
                                      (. (steering.queue-info) :steering-queued)))))
            (it "a test extension tool enqueues through the shared queues in FIFO order"
                (fn []
                  (reset!)
                  (tasks.attach! true)
                  (let [api (test-api.make-runtime-api :enqueue-test)
                        tool {:name :enqueue-test
                              :execute (fn [_ _]
                                         (api.enqueue :follow-up "extension"))}]
                    (api.register :tool tool)
                    (steering.queue! :follow-up "user")
                    (let [result (tool.execute {} {})]
                      (assert.is_true result.ok)
                      (assert.are.equal :follow-up result.queue)
                      (assert.are.same ["user" "extension"] (snap :follow-up))))))
            (it "api enqueue routes steering and updates presenter queue counts"
                (fn []
                  (reset!)
                  (tasks.attach! true)
                  (let [api (test-api.make-runtime-api :enqueue-test)
                        seen (watch :set-status-info)]
                    (api.enqueue :steering "extension steering")
                    (let [invalid (api.enqueue :followup "not public")
                          info (. seen (length seen) :info)]
                      (assert.is_false invalid.ok)
                      (assert.are.equal "unknown queue: followup" invalid.error)
                      (assert.are.same ["extension steering"] (snap :steering))
                      (assert.are.equal 1 info.steering-queued)
                      (assert.are.equal 0 info.follow-up-queued))
                    (assert.are.same ["extension steering"] (snap :steering)))))
            (it "starts opted-in idle follow-ups only at the idle tick"
                (fn []
                  (reset!)
                  (tasks.release! (. (tasks.holder) :hid))
                  (tasks.attach! true)
                  (let [api (test-api.make-runtime-api :enqueue-test)]
                    (api.enqueue :follow-up "plain")
                    (assert.is_nil (?. (tasks.next-start!) :text))
                    (steering.clear-queues!)
                    (let [result (api.enqueue :follow-up "start me"
                                              {:start-if-idle? true})]
                      (assert.is_true result.start-pending?))
                    (assert.are.equal "start me" (?. (tasks.next-start!) :text))
                    (assert.is_nil (?. (tasks.next-start!) :text))
                    (assert.are.same [] (snap :follow-up)))))
            (it "clearing queues removes extension-enqueued messages and idle starts"
                (fn []
                  (reset!)
                  (tasks.attach! true)
                  (let [api (test-api.make-runtime-api :enqueue-test)]
                    (api.enqueue :steering "extension steering")
                    (tasks.release! (. (tasks.holder) :hid))
                    (api.enqueue :follow-up "extension follow-up"
                                 {:start-if-idle? true})
                    (steering.clear-queues!)
                    (assert.are.same [] (snap :steering))
                    (assert.are.same [] (snap :follow-up))
                    (assert.is_nil (?. (tasks.next-start!) :text)))))
            (it "api enqueue fails without an attached interactive runtime"
                (fn []
                  (reset!)
                  (let [api (test-api.make-runtime-api :enqueue-test)
                        result (api.enqueue :follow-up "x")]
                    (assert.is_false result.ok)
                    (assert.are.equal "no interactive runtime" result.error))))
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
                  (assert.are.same [] (snap :follow-up))))
            (it "set-queue-mode! rejects unknown kinds and modes"
                (fn []
                  (reset!)
                  (assert.is_false (steering.set-queue-mode! :steering
                                                             :sometimes))
                  (assert.is_false (steering.set-queue-mode! :bogus :all))
                  (assert.are.equal :one-at-a-time (snap :steering-mode))))
            (it "clear-queues! clears one queue or both"
                (fn []
                  (reset!)
                  (steering.queue! :steering "s")
                  (steering.queue! :follow-up "f")
                  (steering.clear-queues! :steering)
                  (assert.are.same [] (snap :steering))
                  (assert.are.same ["f"] (snap :follow-up))
                  (steering.clear-queues!)
                  (assert.are.same [] (snap :follow-up))))
            (it "queue-snapshot returns copies, not live queue tables"
                (fn []
                  (reset!)
                  (steering.queue! :steering "s")
                  (let [copy (steering.queue-snapshot)]
                    (table.insert copy.steering "mutated")
                    (assert.are.same ["s"] (snap :steering))
                    (assert.are.equal :one-at-a-time copy.steering-mode))))
            (it "rejects the old :followup spelling"
                (fn []
                  (reset!)
                  (assert.is_false (. (steering.queue! :followup "f") :ok))
                  (assert.are.same [] (snap :follow-up))))
            (it "busy input with no mailbox turn (/reload, /handoff) becomes a follow-up"
                (fn []
                  (reset!)
                  (tasks.release! (. (tasks.holder) :hid))
                  (let [result (steering.submit "typed during reload"
                                                {:busy? true})]
                    (assert.are.equal :queued result.action)
                    (assert.are.equal :follow-up result.queue)
                    (assert.are.same [] (snap :steering))
                    (assert.are.same ["typed during reload"] (snap :follow-up)))))
            (it "explicit steering is still rejected when no turn is running"
                (fn []
                  (reset!)
                  (tasks.release! (. (tasks.holder) :hid))
                  (assert.is_false (. (steering.queue! :steering "late") :ok))))
            (it "legacy runtime shims keep a pre-mailbox session's tick working"
                (fn []
                  (reset!)
                  (tasks.release! (. (tasks.holder) :hid))
                  (let [started []]
                    (steering.install-runtime! {:start-follow-up! #(table.insert started
                                                                                 $1)})
                    (assert.is_true (. (tasks.offer! "x" {:turn 0}) :ok))
                    (assert.is_true (steering.start-idle-follow-up!))
                    (assert.are.same ["x"] started)
                    (assert.is_false (steering.start-idle-follow-up!))
                    (steering.install-runtime! nil))))
            (it "handle-input starts a turn when idle"
                (fn []
                  (reset!)
                  (let [result (steering.handle-input {:kind :user-input
                                                       :text "hello"}
                                                      {:busy? false})]
                    (assert.are.equal :start result.action)
                    (assert.are.equal "hello" result.text))))
            (it "handle-input queues steering while busy"
                (fn []
                  (reset!)
                  (let [result (steering.handle-input {:kind :user-input
                                                       :text "steer"}
                                                      {:busy? true})]
                    (assert.are.equal :queued result.action)
                    (assert.are.equal :steering result.queue)
                    (assert.are.same ["steer"] (snap :steering)))))
            (it "handle-input strips > into follow-up while busy"
                (fn []
                  (reset!)
                  (let [result (steering.handle-input {:kind :user-input
                                                       :text "> later "}
                                                      {:busy? true})]
                    (assert.are.equal :queued result.action)
                    (assert.are.equal :follow-up result.queue)
                    (assert.are.same ["later"] (snap :follow-up)))))
            (it "handle-input passes through non user-input kinds"
                (fn []
                  (reset!)
                  (let [input {:kind :other :text "x"}
                        result (steering.handle-input input {:busy? true})]
                    (assert.are.equal :continue result.action)
                    (assert.are.equal input result.input)
                    (assert.are.same [] (snap :steering)))))
            (it "registers a late-order input handler"
                (fn []
                  (reset!)
                  (let [entry (require :fen.extensions.steering)
                        api (test-api.make-runtime-api :steering)]
                    (entry.register api)
                    (let [input-reg (require :fen.core.extensions.register.input)
                          lst (input-reg.list)]
                      (assert.are.equal 1 (length lst))
                      (assert.are.equal :steering (. lst 1 :name))
                      (assert.are.equal 1000 (. lst 1 :order))))))
            (it "registers an introspect snapshot of queue depths"
                (fn []
                  (reset!)
                  (let [entry (require :fen.extensions.steering)
                        api (test-api.make-runtime-api :steering)]
                    (entry.register api)
                    (steering.queue! :steering "s")
                    (let [introspect (require :fen.core.extensions.register.introspect)
                          snapshots (introspect.collect)]
                      (assert.are.equal 1
                                        (. snapshots :steering :queues
                                           :steering-queued))))))))
