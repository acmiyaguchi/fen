;; Session lifecycle command/tool tests.

(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local command-registry (require :fen.core.extensions.register.command))
(local extension-state (require :fen.core.extensions.state))
(local tools (require :fen.core.tools))

(describe "fen.extensions.sessions.commands.session"
  (fn []
    (before_each (fn [] (test-api.reset!)))
    (after_each (fn [] (test-api.reset!)))

    (it "reload tool enqueues rather than reloading inside an active tool turn"
      (fn []
        (var reloads 0)
        (let [api (test-api.make-runtime-api :sessions)
              mod (require :fen.extensions.sessions.commands.session)
              state {:busy? true
                     :turn :agent-tool-call
                     :reload-requests []
                     :reload-modules (fn [] (set reloads (+ reloads 1)))}]
          (mod.register api)
          (let [call (tools.execute-call
                       (tool-registry.merged [])
                       {:name :reload
                        :arguments {:scope "registries"
                                    :reason "rebuild damaged registrations"
                                    :force true}}
                       {:state state}
                       (fn [] nil))]
            (assert.is_false call.result.is-error?)
            (assert.are.equal 0 reloads)
            (assert.are.equal 1 (length state.reload-requests))
            (let [request (. state.reload-requests 1)]
              (assert.are.equal :registries request.scope)
              (assert.are.equal "rebuild damaged registrations" request.reason)
              (assert.is_true request.force?))
            (assert.is_truthy
              (string.find (. call.result.content 1 :text)
                           "after this turn is idle" 1 true)))))))

    (it "keeps ordinary /reload state-preserving while recovery forces known bootstrap paths"
      (fn []
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
                                       (values 0 [] {:checked 0 :reloaded 0
                                                     :changed 0 :failed 0
                                                     :changed-modules []}))
                     :load-extensions (fn [_opts mode]
                                        (table.insert load-modes mode)
                                        {:loaded 0 :changed 0 :failed 0 :extensions []})
                     :reload-model-providers (fn [] 0)
                     :make-agent-from-opts (fn [] replacement)}]
          (mod.register api)
          ;; The legacy slash command stays immediate-at-idle and preserves the
          ;; message table; only the model-facing tool is deferred.
          (command-registry.dispatch "/reload" state)
          (assert.is_true state.busy?)
          (assert.is_true (coroutine.resume state.turn))
          ;; The normal path must retain the original conversation table even
          ;; if a reloadable command body has changed while it was running.
          (assert.are.equal messages state.agent.messages)
          (set state.busy? false)
          (set state.turn nil)
          (table.insert extension-state.tools-extra {:name :stale})
          (command-registry.dispatch "/reload --recover registries" state)
          (assert.is_true (coroutine.resume state.turn))
          (assert.are.equal 0 (length extension-state.tools-extra))))))
