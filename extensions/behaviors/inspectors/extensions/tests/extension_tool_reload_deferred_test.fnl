;; Regression for #627: the model-facing `extension` tool queues its reload for
;; the run's idle boundary instead of swapping the registry under a live turn.

(local h (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))
(local tasks (require :fen.core.tasks))
(local hold (require :fen.testing.tasks))
(local command-registry (require :fen.core.extensions.register.command))

(local EXTENSION-MODULE :fen.extensions.extensions_inspector.commands.extension)

(describe "#627 extension tool reload during a turn"
          (fn []
            (var snapshot nil)
            (before_each (fn []
                           (set snapshot
                                (h.package-loaded-snapshot [EXTENSION-MODULE]))
                           (tasks.reset!)
                           (test-api.reset!)))
            (after_each (fn []
                          (tasks.reset!)
                          (test-api.reset!)
                          (h.restore-package-loaded! snapshot)))
            (it "queues the reload as an exclusive job, leaves the registry and the turn's agent alone, and runs it after the turn"
                (fn []
                  (let [inspector-api (test-api.make-runtime-api :extensions_inspector)
                        demo-api (test-api.make-runtime-api :demo-ext)
                        mod (h.reload-module EXTENSION-MODULE)]
                    (mod.register inspector-api)
                    (demo-api.register :tool
                                       {:name :demo
                                        :parameters {:type :object}
                                        :execute (fn [] nil)})
                    (hold.hold-turn!)
                    (let [old-agent {:messages [{:role :user}]}
                          reloads {:count 0}
                          state {:busy? true
                                 :turn {:id 1}
                                 :agent old-agent
                                 :reload-extension (fn [_]
                                                     (set reloads.count
                                                          (+ reloads.count 1))
                                                     (values true nil))}
                          call (tools.execute-call (tool-registry.merged [])
                                                   {:name :extension
                                                    :arguments {:action "reload"
                                                                :name "demo-ext"}}
                                                   {: state})]
                      (assert.is_false call.result.is-error?)
                      (assert.are.equal 0 reloads.count)
                      (assert.are.equal old-agent state.agent)
                      (assert.are.equal 1 (. (tasks.snapshot) :jobs))
                      ;; The turn ends; the scheduler runs the job, which
                      ;; dispatches the reload command line.
                      (tasks.drop-current!)
                      (var line nil)
                      (let [orig command-registry.dispatch]
                        (set command-registry.dispatch
                             (fn [l _state] (set line l)))
                        (let [r (tasks.next-job!)]
                          (assert.are.equal :exclusive r.kind)
                          (coroutine.resume r.co))
                        (set command-registry.dispatch orig))
                      (assert.are.equal "/reload-extension demo-ext" line)))))
            (it "rejects an empty name without queueing"
                (fn []
                  (let [inspector-api (test-api.make-runtime-api :extensions_inspector)
                        mod (h.reload-module EXTENSION-MODULE)]
                    (mod.register inspector-api)
                    (let [state {:busy? true}
                          call (tools.execute-call (tool-registry.merged [])
                                                   {:name :extension
                                                    :arguments {:action "reload"}}
                                                   {: state})]
                      (assert.is_true call.result.is-error?)
                      (assert.are.equal 0 (. (tasks.snapshot) :jobs))))))))
