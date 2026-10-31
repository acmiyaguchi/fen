;; Regression for #627: the model-facing `extension` tool queues its reload for
;; the run's idle boundary instead of swapping the registry under a live turn.

(local h (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local reload-request (require :fen.reload_request))
(local tools (require :fen.core.tools))

(local EXTENSION-MODULE :fen.extensions.extensions_inspector.commands.extension)

(describe "#627 extension tool reload during a turn"
          (fn []
            (var snapshot nil)
            (before_each (fn []
                           (set snapshot
                                (h.package-loaded-snapshot [EXTENSION-MODULE]))
                           (test-api.reset!)))
            (after_each (fn []
                          (test-api.reset!)
                          (h.restore-package-loaded! snapshot)))
            (it "queues the reload, leaves the registry and the turn's agent alone, and runs it from the idle drain"
                (fn []
                  (let [inspector-api (test-api.make-runtime-api :extensions_inspector)
                        demo-api (test-api.make-runtime-api :demo-ext)
                        mod (h.reload-module EXTENSION-MODULE)]
                    (mod.register inspector-api)
                    (demo-api.register :tool
                                       {:name :demo
                                        :parameters {:type :object}
                                        :execute (fn [] nil)})
                    (let [old-agent {:messages [{:role :user}]}
                          reloads {:count 0}
                          state {:busy? true
                                 :turn {:id 1}
                                 :reload-requests []
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
                      (assert.are.equal 1 (length state.reload-requests))
                      (let [request (. state.reload-requests 1)]
                        (assert.are.equal :extension request.scope)
                        (assert.are.equal "/reload-extension demo-ext"
                                          (reload-request.command-line request)))
                      ;; Busy: the drain does nothing. Idle: it hands the request to the dispatcher.
                      (assert.is_false (reload-request.drain! state
                                                              (fn [_]
                                                                (error "ran while busy"))))
                      (set state.busy? false)
                      (set state.turn nil)
                      (var line nil)
                      (reload-request.drain! state
                                             (fn [request]
                                               (set line
                                                    (reload-request.command-line request))))
                      (assert.are.equal "/reload-extension demo-ext" line)))))
            (it "rejects an empty name without queueing"
                (fn []
                  (let [inspector-api (test-api.make-runtime-api :extensions_inspector)
                        mod (h.reload-module EXTENSION-MODULE)]
                    (mod.register inspector-api)
                    (let [state {:busy? true :reload-requests []}
                          call (tools.execute-call (tool-registry.merged [])
                                                   {:name :extension
                                                    :arguments {:action "reload"}}
                                                   {: state})]
                      (assert.is_true call.result.is-error?)
                      (assert.are.equal 0 (length state.reload-requests))))))))
