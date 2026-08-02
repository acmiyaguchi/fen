;; Session lifecycle command/tool tests.

(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))
(local log (require :fen.util.log))
(local profile-state (require :fen.extensions.profiler.state))

(describe "fen.extensions.sessions.commands.session"
  (fn []
    (before_each
      (fn []
        (test-api.reset!)
        (profile-state.reset!)))
    (after_each
      (fn []
        (profile-state.reset!)
        (test-api.reset!)))

    (it "reload tool cooperatively reloads while preserving the message table"
      (fn []
        (let [api (test-api.make-runtime-api :sessions)
              mod (require :fen.extensions.sessions.commands.session)
              messages []
              old-agent {:messages messages :tools [{:name :old}]}
              replacement {:messages [] :tools []}
              reload-opts []
              load-modes []
              state {:agent old-agent
                     :opts {}
                     :on-event (fn [_event] nil)
                     :agent-extra {}
                     :reload-modules (fn [yield! opts]
                                       (table.insert reload-opts opts)
                                       (yield! :core)
                                       (log.warn "coroutine reload warning")
                                       (values 1 [] {:checked 1 :reloaded 1 :changed 1 :failed 0
                                                     :changed-modules [:fen.core.agent]}))
                     :load-extensions (fn [_opts mode]
                                        (table.insert load-modes mode)
                                        (when mode.yield (mode.yield {:phase :extension :name :x}))
                                        {:loaded 1 :changed 0 :failed 0 :extensions []})
                     :reload-model-providers (fn [] 2)
                     :make-agent-from-opts (fn [_opts _on-event _extra] replacement)}]
          (profile-state.start! {:period 1000000})
          (mod.register api)
          (let [registered (tool-registry.merged [])
                yielded []
                call (tools.execute-call
                       registered {:name :reload :arguments {:force true}}
                       {:state state :agent old-agent}
                       (fn [progress] (table.insert yielded progress)))]
            (assert.are.equal replacement state.agent)
            (assert.are.equal messages replacement.messages)
            (assert.are.equal old-agent.tools replacement.tools)
            (assert.are.equal :reload (. old-agent.tools 1 :name))
            (assert.is_true (. reload-opts 1 :force?))
            (assert.are.same {:tui true} (. load-modes 1 :skip-names))
            (assert.are.same {:tui true} (. load-modes 2 :only-names))
            (assert.is_true (> (length yielded) 0))
            (let [phases {}]
              (each [_ progress (ipairs yielded)]
                (when (= (type progress) :table)
                  (tset phases progress.phase true)))
              (assert.is_true (. phases :after-core))
              (assert.is_true (. phases :after-extensions))
              (assert.is_true (. phases :after-tui))
              (assert.is_true (. phases :after-model-providers)))
            (assert.is_false call.result.is-error?)
            (assert.is_truthy
              (string.find (. call.result.content 1 :text)
                           "/reload core 1/1 changed" 1 true))
            (assert.is_truthy
              (string.find (. call.result.content 1 :text)
                           "core changed: fen.core.agent" 1 true))
            (assert.is_truthy
              (string.find (. call.result.content 1 :text)
                           "timings:" 1 true))
            (assert.is_truthy
              (string.find (. call.result.content 1 :text)
                           "tui=" 1 true))
            (assert.is_truthy
              (string.find (. call.result.content 1 :text)
                           "model-providers=" 1 true))
            (assert.is_truthy
              (string.find (. call.result.content 1 :text)
                           "[warn] coroutine reload warning" 1 true))
            (profile-state.stop!)
            (let [names {}]
              (each [_ span (ipairs profile-state.spans)]
                (tset names span.name true))
              (assert.is_true (. names "reload"))
              (assert.is_true (. names "reload-core"))
              (assert.is_true (. names "reload-extensions"))
              (assert.is_true (. names "reload-tui"))
              (assert.is_true (. names "reload-model-providers"))
              (assert.is_true (. names "reload-agent-rebuild")))))))))
