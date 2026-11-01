;; Abandonment: when the presenter returns (quit, rpc exit) or crashes while a
;; turn or exclusive coroutine is still suspended, nothing resumes that
;; coroutine to completion, so spawn-holder's xpcall never runs. The runtime's
;; shutdown must release the session holder itself.

(local tasks (require :fen.core.tasks))

(local STUBBED [:fen.core.extensions.loader
                :fen.core.extensions.loader.reload
                :fen.core.extensions.register.presenter
                :fen.core.llm.models
                :fen.session_lifecycle
                :fen.interactive])

(var saved {})

(fn stub! [presenter-run]
  (set saved {})
  (each [_ name (ipairs STUBBED)]
    (tset saved name (or (. package.loaded name) false)))
  (tset package.loaded :fen.core.extensions.loader
        {:load! (fn [] nil) :reload-extension! (fn [] nil)})
  (tset package.loaded :fen.core.extensions.loader.reload
        {:snapshot-core! (fn [] nil) :reload-core! (fn [] nil)})
  (tset package.loaded :fen.core.llm.models {:register-providers! (fn [] nil)})
  (tset package.loaded :fen.core.extensions.register.presenter
        {:init-active-presenter (fn []
                                  true)
         :run-active-presenter (fn [ctx]
                                 (values true (presenter-run ctx)))
         :shutdown-active-presenter (fn []
                                      true)})
  (tset package.loaded :fen.session_lifecycle
        {:resolve-backend (fn [] {})
         :start! (fn [] (values {} 0))
         :make-flush (fn [] (fn [] nil))
         :install! (fn [] nil)
         :close! (fn [] nil)
         :uninstall! (fn [] nil)
         :cwd (fn [] "/")
         :backend-info (fn [] {})})
  (tset package.loaded :fen.interactive nil)
  (let [interactive (require :fen.interactive)]
    (set interactive.make-agent-from-opts
         (fn [_resolve _opts _on-event extra]
           {:messages [] :model "stub" :extra extra}))
    interactive))

(fn unstub! []
  (each [name v (pairs saved)]
    (tset package.loaded name (when v v))))

(describe "interactive shutdown releases an abandoned holder"
          (fn []
            (before_each (fn [] (tasks.reset!)))
            (after_each (fn [] (unstub!) (tasks.reset!)))
            (it "quit while a turn is suspended"
                (fn []
                  (let [interactive (stub! (fn [ctx]
                                             (ctx.state.submit-user-turn! ctx.state
                                                                          "work")
                                             (assert.are.equal :turn
                                                               (. (tasks.holder)
                                                                  :kind))
                                             (tasks.offer! "unread")
                                             0))
                        returned []]
                    ((. (require :fen.core.extensions.events) :on) :steering-returned
                                                                   #(table.insert returned
                                                                                  $1)
                                                                   :holder-release-test)
                    (assert.are.equal 0 (interactive.run! {} (fn [] {})))
                    ((. (require :fen.core.extensions.events)
                        :unregister-by-owner) :holder-release-test)
                    (assert.are.equal :none (. (tasks.holder) :kind))
                    (assert.are.same ["unread"] (?. returned 1 :texts)))))
            (it "presenter crash while an exclusive coroutine is suspended"
                (fn []
                  (let [interactive (stub! (fn [ctx]
                                             (let [co ((. (require :fen.testing.tasks)
                                                          :hold-exclusive!))]
                                               (set ctx.state.turn co)
                                               (set ctx.state.busy? true))
                                             (assert (= :exclusive
                                                        (. (tasks.holder) :kind)))
                                             (error "presenter blew up")))
                        real-exit os.exit
                        real-stderr io.stderr]
                    (set os.exit (fn [code] (error {:exit code})))
                    (set io.stderr {:write (fn [] nil)})
                    (let [(ok? err) (pcall interactive.run! {} (fn [] {}))]
                      (set os.exit real-exit)
                      (set io.stderr real-stderr)
                      (assert.is_false ok?)
                      (assert.are.equal 1 (?. err :exit)))
                    (assert.are.equal :none (. (tasks.holder) :kind)))))))
