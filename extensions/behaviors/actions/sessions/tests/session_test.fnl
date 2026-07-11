;; Session lifecycle command/tool tests.

(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))

(describe "fen.extensions.sessions.commands.session"
  (fn []
    (before_each test-api.reset!)
    (after_each test-api.reset!)

    (it "reload tool cooperatively reloads while preserving the message table"
      (fn []
        (let [api (test-api.make-runtime-api :sessions)
              mod (require :fen.extensions.sessions.commands.session)
              messages []
              old-agent {:messages messages}
              replacement {:messages []}
              reload-opts []
              state {:agent old-agent
                     :opts {}
                     :on-event (fn [_event] nil)
                     :agent-extra {}
                     :reload-modules (fn [yield! opts]
                                       (table.insert reload-opts opts)
                                       (yield! :core)
                                       (values 1 [] {:checked 1 :reloaded 1 :changed 1 :failed 0}))
                     :make-agent-from-opts (fn [_opts _on-event _extra] replacement)}]
          (mod.register api)
          (let [registered (tool-registry.merged [])
                yielded []
                call (tools.execute-call
                       registered {:name :reload :arguments {:force true}} {:state state}
                       (fn [progress] (table.insert yielded progress)))]
            (assert.are.equal replacement state.agent)
            (assert.are.equal messages replacement.messages)
            (assert.is_true (. reload-opts 1 :force?))
            (assert.is_true (> (length yielded) 0))
            (assert.is_false call.result.is-error?)
            (assert.is_truthy
              (string.find (. call.result.content 1 :text)
                           "/reload core 1/1 changed" 1 true))))))))
