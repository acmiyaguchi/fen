(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local command-registry (require :fen.core.extensions.register.command))
(local extension-state (require :fen.core.extensions.state))
(local tools (require :fen.core.tools))

(describe "fen.extensions.sessions.commands.session"
          (fn []
            (before_each (fn []
                           (test-api.reset!)
                           ((. (require :fen.core.tasks) :reset!))))
            (after_each (fn []
                          (test-api.reset!)
                          ((. (require :fen.core.tasks) :reset!))))
            (it "reload tool enqueues rather than reloading inside an active tool turn"
                (fn []
                  (var reloads 0)
                  (let [api (test-api.make-runtime-api :sessions)
                        mod (require :fen.extensions.sessions.commands.session)
                        state {:busy? true
                               :turn :agent-tool-call
                               :reload-modules (fn []
                                                 (set reloads (+ reloads 1)))}]
                    ((. (require :fen.testing.tasks) :hold-turn!))
                    (mod.register api)
                    (let [call (tools.execute-call (tool-registry.merged [])
                                                   {:name :reload
                                                    :arguments {:scope "registries"
                                                                :reason "rebuild damaged registrations"
                                                                :force true}}
                                                   {:state state} (fn [] nil))]
                      (assert.is_false call.result.is-error?)
                      (assert.are.equal 0 reloads)
                      ;; one exclusive job waits for the turn
                      (assert.are.equal 1
                                        (. ((. (require :fen.core.tasks)
                                               :snapshot))
                                           :jobs))
                      (assert.is_truthy (string.find (. call.result.content 1
                                                        :text)
                                                     "after this turn is idle" 1
                                                     true)))))))
          (it "keeps ordinary /reload state-preserving while recovery forces known bootstrap paths"
              (fn []
                ((. (require :fen.core.tasks) :reset!))
                (let [api (test-api.make-runtime-api :sessions)
                      mod (require :fen.extensions.sessions.commands.session)
                      messages [{:role :user}]
                      old-agent {:messages messages}
                      replacement {:messages []}
                      core-opts []
                      load-modes []
                      state {:busy? false
                             :agent old-agent
                             :opts {}
                             :on-event (fn [] nil)
                             :agent-extra {}
                             :reload-modules (fn [_yield opts]
                                               (table.insert core-opts opts)
                                               (values 0 []
                                                       {:checked 0
                                                        :reloaded 0
                                                        :changed 0
                                                        :failed 0
                                                        :changed-modules []}))
                             :load-extensions (fn [_opts mode]
                                                (table.insert load-modes mode)
                                                {:loaded 0
                                                 :changed 0
                                                 :failed 0
                                                 :extensions []})
                             :reload-model-providers (fn [] 0)
                             :make-agent-from-opts (fn [] replacement)}]
                  (mod.register api)
                  (command-registry.dispatch "/reload" state)
                  (assert.is_true state.busy?)
                  (assert.is_true (coroutine.resume state.turn))
                  (assert.are.equal messages state.agent.messages)
                  ;; Finish the reload coroutine so its exclusive holder releases.
                  (while (not= :dead (coroutine.status state.turn))
                    (coroutine.resume state.turn))
                  (set state.busy? false)
                  (set state.turn nil)
                  (table.insert extension-state.tools-extra {:name :stale})
                  (command-registry.dispatch "/reload --recover registries"
                                             state)
                  (assert.is_true (coroutine.resume state.turn))
                  (assert.are.equal 0 (length extension-state.tools-extra))))
              (it "rejects unrecognized /reload text instead of reloading"
                  (fn []
                    ((. (require :fen.core.tasks) :reset!))
                    (var reloads 0)
                    (let [api (test-api.make-runtime-api :sessions)
                          mod (require :fen.extensions.sessions.commands.session)
                          state {:busy? false
                                 :reload-modules (fn []
                                                   (set reloads (+ reloads 1)))}]
                      (mod.register api)
                      (command-registry.dispatch "/reload please" state)
                      (assert.is_false state.busy?)
                      (assert.is_nil state.turn)
                      (assert.are.equal 0 reloads))))
              (it "/reload waits behind a pending turn start, then runs after that turn"
                  (fn []
                    ((. (require :fen.core.tasks) :reset!))
                    (let [tasks (require :fen.core.tasks)
                          events (require :fen.core.extensions.events)
                          infos []
                          api (test-api.make-runtime-api :sessions)
                          mod (require :fen.extensions.sessions.commands.session)
                          state {:busy? false}]
                      (events.on :info #(table.insert infos $1.text)
                                 :reload-queued-test)
                      (mod.register api)
                      (tasks.offer! "queued prompt")
                      (command-registry.dispatch "/reload" state)
                      (events.unregister-by-owner :reload-queued-test)
                      (assert.is_nil state.turn)
                      (assert.are.equal :none (. (tasks.holder) :kind))
                      (assert.is_truthy (string.find (or (. infos 1) "")
                                                     "queued" 1 true))
                      (let [r (tasks.next-job! {:make-turn (fn [] (fn [] nil))})]
                        (assert.are.equal :turn r.kind)
                        (assert.are.equal "queued prompt" r.item.text)
                        (coroutine.resume r.co))
                      (assert.are.equal :exclusive (. (tasks.next-job!) :kind)))))
              (it "/reload honors Ctrl-C between phases (d)"
                  (fn []
                    ((. (require :fen.core.tasks) :reset!))
                    (var reloads 0)
                    (let [tasks (require :fen.core.tasks)
                          events (require :fen.core.extensions.events)
                          seen []
                          api (test-api.make-runtime-api :sessions)
                          mod (require :fen.extensions.sessions.commands.session)
                          state {:busy? false
                                 :reload-modules (fn []
                                                   (set reloads (+ reloads 1)))}]
                      (events.on :cancelled #(table.insert seen $1)
                                 :reload-cancel-test)
                      (mod.register api)
                      (command-registry.dispatch "/reload" state)
                      (assert.is_true state.busy?)
                      (coroutine.resume state.turn)
                      (assert.is_true (tasks.cancel-current!))
                      (while (not= :dead (coroutine.status state.turn))
                        (coroutine.resume state.turn))
                      (events.unregister-by-owner :reload-cancel-test)
                      (assert.are.equal 0 reloads
                                        "no phase ran after the cancel")
                      (assert.are.equal 1 (length seen))
                      (assert.are.equal :none (. (tasks.holder) :kind)))))))
