(local test-api (require :fen.core.extensions.test_api))
(local register (require :fen.core.extensions.register))
(local agent-mod (require :fen.core.agent))
(local interactive (require :fen.interactive))
(local lifecycle (require :fen.session_lifecycle))
(local control (require :fen.session_control))

(fn make-backend [?opts]
  (let [opts (or ?opts {})
        cwd (lifecycle.cwd)
        store {:id "exact-session-id" :path "/tmp/exact-session-id.jsonl"
               :cwd cwd :messages []}
        backend {:name :fake}]
    (set backend.open (fn [_] store))
    (set backend.create (fn [_] store))
    (set backend.open-existing (fn [_] store))
    (set backend.append (fn [_ message]
                          (table.insert store.messages message)))
    (set backend.close (fn [_] nil))
    (set backend.load (fn [_]
                        (when opts.malformed? (error "malformed transcript"))
                        (let [out []]
                          (each [_ message (ipairs store.messages)]
                            (table.insert out message))
                          out)))
    (set backend.find (fn [_ target] target))
    (set backend.list (fn [_ _] [store]))
    (set backend.latest (fn [_] store.path))
    (set backend.get (fn [_ id]
                       (when (= id store.id) store)))
    (set backend.acquire-lock (fn [_]
                                (when (not opts.busy?) (fn [] nil))))
    (set backend.info (fn [session]
                        {:backend :fake :id session.id :path session.path
                         :cwd session.cwd}))
    {:backend backend :store store}))

(describe "fen.session_control"
  (fn []
    (var old-make nil)
    (var old-step nil)

    (before_each
      (fn []
        (test-api.reset!)
        (set old-make interactive.make-agent-from-opts)
        (set old-step agent-mod.step)))

    (after_each
      (fn []
        (set interactive.make-agent-from-opts old-make)
        (set agent-mod.step old-step)
        (lifecycle.uninstall!)
        (test-api.reset!)))

    (it "creates, lists, and shows an exactly addressed durable session"
      (fn []
        (let [fixture (make-backend)]
          (register.register :session-backend fixture.backend :session-control-test)
          (let [(created create-code) (control.new {:session-backend :fake})
                (listed list-code) (control.list {:session-backend :fake})
                (shown show-code) (control.show "exact-session-id"
                                                {:session-backend :fake})]
            (assert.are.equal 0 create-code)
            (assert.is_true created.ok)
            (assert.are.equal "exact-session-id" created.session.id)
            (assert.are.equal 0 list-code)
            (assert.are.equal 1 (length listed.sessions))
            (assert.are.equal 0 show-code)
            (assert.is_true shown.ok)
            (assert.are.equal 0 (length shown.messages))))))

    (it "rejects unknown exact ids without falling back"
      (fn []
        (let [fixture (make-backend)]
          (register.register :session-backend fixture.backend :session-control-test)
          (let [(result code) (control.show "exact" {:session-backend :fake})]
            (assert.are.equal 2 code)
            (assert.is_false result.ok)
            (assert.are.equal :session_not_found result.error.code)))))

    (it "continues context and returns only messages from the submitted turn"
      (fn []
        (let [fixture (make-backend)]
          (register.register :session-backend fixture.backend :session-control-test)
          (set interactive.make-agent-from-opts
               (fn [_ _ _ _] {:messages []}))
          (set agent-mod.step
               (fn [agent prompt]
                 (let [prior (length agent.messages)]
                   (table.insert agent.messages {:role :user :content prompt})
                   (table.insert agent.messages
                                 {:role :assistant
                                  :content [{:type :text
                                             :text (.. "prior=" (tostring prior))}]
                                  :stop-reason :stop
                                  :usage {:input prior :output 1}})
                   (.. "prior=" (tostring prior)))))
          (let [(first first-code)
                (control.send "exact-session-id" "one"
                              {:session-backend :fake} (fn [_] {}))
                (second second-code)
                (control.send "exact-session-id" "two"
                              {:session-backend :fake} (fn [_] {}))]
            (assert.are.equal 0 first-code)
            (assert.are.equal "prior=0" first.turn.result)
            (assert.are.equal 2 (length first.turn.messages))
            (assert.are.equal 0 second-code)
            (assert.are.equal "prior=2" second.turn.result)
            (assert.are.equal 2 (length second.turn.messages))
            (assert.are.equal 4 (length fixture.store.messages))))))

    (it "reports provider-style failures with exit class one"
      (fn []
        (let [fixture (make-backend)]
          (register.register :session-backend fixture.backend :session-control-test)
          (set interactive.make-agent-from-opts (fn [_ _ _ _] {:messages []}))
          (set agent-mod.step
               (fn [agent prompt]
                 (table.insert agent.messages {:role :user :content prompt})
                 (table.insert agent.messages
                               {:role :assistant :content []
                                :stop-reason :error :error-message "boom"})
                 "[error] boom"))
          (let [(result code)
                (control.send "exact-session-id" "fail"
                              {:session-backend :fake} (fn [_] {}))]
            (assert.are.equal 1 code)
            (assert.is_false result.ok)
            (assert.are.equal :turn_failed result.error.code)))))

    (it "rejects concurrent mutation before loading or appending"
      (fn []
        (let [fixture (make-backend {:busy? true})]
          (register.register :session-backend fixture.backend :session-control-test)
          (let [(result code)
                (control.send "exact-session-id" "blocked"
                              {:session-backend :fake} (fn [_] {}))]
            (assert.are.equal 2 code)
            (assert.are.equal :session_busy result.error.code)
            (assert.are.equal 0 (length fixture.store.messages))))))

    (it "reports malformed transcripts without mutating them"
      (fn []
        (let [fixture (make-backend {:malformed? true})]
          (register.register :session-backend fixture.backend :session-control-test)
          (let [(shown show-code)
                (control.show "exact-session-id" {:session-backend :fake})
                (sent send-code)
                (control.send "exact-session-id" "nope"
                              {:session-backend :fake} (fn [_] {}))]
            (assert.are.equal 2 show-code)
            (assert.are.equal :malformed_session shown.error.code)
            (assert.are.equal 2 send-code)
            (assert.are.equal :malformed_session sent.error.code)
            (assert.are.equal 0 (length fixture.store.messages))))))))
