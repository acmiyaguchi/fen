;; Known bug #627: the `extension` tool's action=reload reloads synchronously mid-turn and swaps state.agent under the running turn.

(local h (require :fen.testing))
(local {: known-bug} h)
(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))

(local EXTENSION-MODULE :fen.extensions.extensions_inspector.commands.extension)

(fn tool-names [tool-list]
  (let [out {}]
    (each [_ t (ipairs (or tool-list []))]
      (tset out (tostring t.name) true))
    out))

(describe "#627 extension tool reload during a turn"
          (fn []
            (var snapshot nil)
            (var session-lifecycle nil)
            (before_each (fn []
                           (set snapshot
                                (h.package-loaded-snapshot [EXTENSION-MODULE
                                                            :fen.session_lifecycle]))
                           (test-api.reset!)))
            (after_each (fn []
                          (when session-lifecycle
                            (session-lifecycle.uninstall!))
                          (test-api.reset!)
                          (h.restore-package-loaded! snapshot)))
            (it "runs reload-extension while busy, bypasses the idle queue, and orphans the turn's agent from session flushes"
                (fn []
                  (known-bug 627
                             (fn []
                               (set session-lifecycle
                                    (require :fen.session_lifecycle))
                               (let [inspector-api (test-api.make-runtime-api :extensions_inspector)
                                     demo-api (test-api.make-runtime-api :demo-ext)
                                     mod (h.reload-module EXTENSION-MODULE)]
                                 (mod.register inspector-api)
                                 (demo-api.register :tool
                                                    {:name :doomed
                                                     :parameters {:type :object}
                                                     :execute (fn [] nil)})
                                 ;; turn_submit captured this agent; its tools are a make-agent snapshot.
                                 (let [old-agent {:messages [{:role :user}]
                                                  :tools (tool-registry.merged [])}
                                       reloads {:count 0 :while-busy 0}
                                       flushes {:count 0}
                                       state {:busy? true
                                              :turn {:id 1}
                                              :reload-requests []
                                              :opts {}
                                              :on-event (fn [_] nil)
                                              :agent-extra {}
                                              :flush (fn []
                                                       (set flushes.count
                                                            (+ flushes.count 1)))}]
                                   (set state.agent old-agent)
                                   ;; The loader's first step: drop the owner's contributions.
                                   (set state.reload-extension
                                        (fn [name]
                                          (set reloads.count
                                               (+ reloads.count 1))
                                          (when state.busy?
                                            (set reloads.while-busy
                                                 (+ reloads.while-busy 1)))
                                          (register-registry.unregister-by-owner name)
                                          (values true nil)))
                                   (set state.make-agent-from-opts
                                        (fn [_ _ _]
                                          {:messages []
                                           :tools (tool-registry.merged [])}))
                                   (session-lifecycle.install! state)
                                   (let [call (tools.execute-call (tool-registry.merged [])
                                                                  {:name :extension
                                                                   :arguments {:action "reload"
                                                                               :name "demo-ext"}}
                                                                  {: state})
                                         new-agent state.agent]
                                     ;; The rest of the turn appends to the agent it captured.
                                     (events.emit {:type :message-appended
                                                   :agent old-agent})
                                     (let [flushes-after-old flushes.count]
                                       ;; Control: the replacement agent does flush.
                                       (events.emit {:type :message-appended
                                                     :agent new-agent})
                                       (and (= false call.result.is-error?)
                                            (= 1 reloads.while-busy)
                                            ;; Not routed through reload_request's idle queue.
                                            (= 0 (length state.reload-requests))
                                            (not= old-agent new-agent)
                                            (= old-agent.messages
                                               new-agent.messages)
                                            ;; The running turn still sees a tool whose owner is gone.
                                            (. (tool-names old-agent.tools)
                                               :doomed)
                                            (= nil
                                               (. (tool-names (tool-registry.merged []))
                                                  :doomed))
                                            (= 0 flushes-after-old)
                                            (= 1 flushes.count))))))))))))
