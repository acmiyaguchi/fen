(local run-state (require :fen.run_state))

(fn make-cfg []
  (let [calls {:opened [] :closed [] :flushes [] :loaded []
               :found [] :listed [] :extension-loads [] :extension-reloads []
               :model-reloads 0 :submitted []}
        backend-a {:name :a}
        backend-b {:name :b}
        session-lifecycle {}
        extension-loader {}
        models-mod {}]
    (set session-lifecycle.open
         (fn [opts backend]
           (table.insert calls.opened {:opts opts :backend backend})
           {:backend backend.name :kind :open}))
    (set session-lifecycle.close!
         (fn [backend session]
           (table.insert calls.closed {:backend backend :session session})
           true))
    (set session-lifecycle.make-flush
         (fn [backend agent session last-saved]
           (table.insert calls.flushes
                         {:backend backend :agent agent :session session
                          :last-saved last-saved})
           (fn [] :flushed)))
    (set session-lifecycle.backend-info
         (fn [backend session]
           {:backend backend.name :id session.id}))
    (set backend-a.open-existing (fn [ref ?yield]
                                   (when ?yield (?yield))
                                   {:backend :a :ref ref}))
    (set backend-a.load (fn [ref ?yield]
                          (when ?yield (?yield))
                          (table.insert calls.loaded {:backend :a :ref ref})
                          [:loaded-a]))
    (set backend-a.find (fn [cwd target ?yield]
                          (when ?yield (?yield))
                          (table.insert calls.found {:backend :a :cwd cwd :target target})
                          :found-a))
    (set backend-a.list (fn [cwd limit ?yield]
                          (when ?yield (?yield))
                          (table.insert calls.listed {:backend :a :cwd cwd :limit limit})
                          [:listed-a]))
    (set backend-b.open-existing (fn [ref ?yield]
                                   (when ?yield (?yield))
                                   {:backend :b :ref ref}))
    (set backend-b.load (fn [ref ?yield]
                          (when ?yield (?yield))
                          (table.insert calls.loaded {:backend :b :ref ref})
                          [:loaded-b]))
    (set backend-b.find (fn [cwd target ?yield]
                          (when ?yield (?yield))
                          (table.insert calls.found {:backend :b :cwd cwd :target target})
                          :found-b))
    (set backend-b.list (fn [cwd limit ?yield]
                          (when ?yield (?yield))
                          (table.insert calls.listed {:backend :b :cwd cwd :limit limit})
                          [:listed-b]))
    (set extension-loader.load!
         (fn [opts mode]
           (table.insert calls.extension-loads {:opts opts :mode mode})
           :loaded))
    (set extension-loader.reload-extension!
         (fn [name]
           (table.insert calls.extension-reloads name)
           :reloaded))
    (set models-mod.register-providers!
         (fn []
           (set calls.model-reloads (+ calls.model-reloads 1))
           :models))
    {:cfg {:opts {:presenter :tui}
           :on-event (fn [_] nil)
           :agent {:messages []}
           :session {:id :s1}
           :flush (fn [] :flush)
           :session-backend backend-a
           :make-agent-from-opts (fn [] :agent)
           :state-box {:state nil}
           :session-lifecycle session-lifecycle
           :extension-loader extension-loader
           :models-mod models-mod
           :reload-modules (fn [] :reload)
           :agent-extra {:get-steering (fn [] nil)}
           :update-queue-status (fn [] :status)
           :submit-user-turn! (fn [state line ?opts]
                                (table.insert calls.submitted
                                              {:state state :line line :opts ?opts})
                                {:ok true})}
     :backend-a backend-a
     :backend-b backend-b
     :calls calls}))

(describe "fen.run_state"
  (fn []
    (it "builds the runtime state and installs it in the state box"
      (fn []
        (let [fixture (make-cfg)
              state (run-state.make fixture.cfg)]
          (assert.are.equal state fixture.cfg.state-box.state)
          (assert.are.equal fixture.cfg.opts state.opts)
          (assert.are.equal fixture.cfg.agent state.agent)
          (assert.are.equal fixture.backend-a state.session-backend)
          (assert.is_false state.busy?)
          (assert.are.equal 0 state.turn-id)
          (assert.is_false state.cancel-requested?)
          (assert.is_nil state.turn)
          (assert.is_function state.submit-user-turn!))))

    (it "uses the current session backend through reload-safe closures"
      (fn []
        (let [fixture (make-cfg)
              state (run-state.make fixture.cfg)]
          (assert.are.same [:loaded-a] (state.load-session :one))
          (set state.session-backend fixture.backend-b)
          (assert.are.same [:loaded-b] (state.load-session :two))
          (assert.are.equal :found-b (state.find-session "/p" :latest))
          (assert.are.same [:listed-b] (state.list-sessions "/p" 3))
          (assert.are.equal :b (. (state.open-existing-session :ref) :backend))
          (assert.are.equal :b (. (state.session-info {:id :sid}) :backend)))))

    (it "returns an empty session list when no backend is active"
      (fn []
        (let [fixture (make-cfg)
              state (run-state.make fixture.cfg)]
          (set state.session-backend nil)
          (assert.are.same [] (state.list-sessions "/p" 5))
          (assert.is_nil (state.load-session :missing)))))

    (it "delegates extension/model reload helpers and turn submission"
      (fn []
        (let [fixture (make-cfg)
              state (run-state.make fixture.cfg)]
          (assert.are.equal :loaded (state.load-extensions {:x true} {:interactive? true}))
          (assert.are.equal :reloaded (state.reload-extension :queue))
          (assert.are.equal :models (state.reload-model-providers))
          (assert.are.equal :reload (state.reload-modules))
          (assert.is_true (. (state.submit-user-turn! "hello" {:when-busy :reject}) :ok))
          (assert.are.equal 1 (length fixture.calls.extension-loads))
          (assert.are.equal :queue (. fixture.calls.extension-reloads 1))
          (assert.are.equal 1 fixture.calls.model-reloads)
          (assert.are.equal state (. fixture.calls.submitted 1 :state))
          (assert.are.equal "hello" (. fixture.calls.submitted 1 :line))))))
)
