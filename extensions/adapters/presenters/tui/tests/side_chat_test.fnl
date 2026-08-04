;; Workspace-native /btw side conversations.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local command-registry (require :fen.core.extensions.register.command))
(local agent-mod (require :fen.core.agent))
(local turn-submit (require :fen.turn_submit))
(local original-step agent-mod.step)
(local state (require :fen.extensions.tui.state))
(local workspaces (require :fen.extensions.tui.workspaces))
(local side-chat (require :fen.extensions.tui.side_chat))
(local input (require :fen.extensions.tui.input))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local tui (require :fen.extensions.tui))

(var captured-opts nil)
(var runtime nil)

(fn fake-step [agent prompt _cancel]
  (table.insert agent.messages {:role :user :content prompt})
  (agent.on-event {:type :message-appended
                   :agent agent :index (length agent.messages)
                   :message (. agent.messages (length agent.messages))})
  (agent.on-event {:type :assistant-text-delta
                   :content-index 1 :delta "side "})
  (coroutine.yield)
  (agent.on-event {:type :assistant-text-delta
                   :content-index 1 :delta "reply"})
  (let [reply {:role :assistant
               :content [{:type :text :text "side reply"}]
               :stop-reason :stop
               :usage {:input 7 :output 2}}]
    (table.insert agent.messages reply)
    (agent.on-event {:type :llm-end :usage reply.usage})
    (agent.on-event {:type :message-appended
                     :agent agent :index (length agent.messages)
                     :message reply})
    (agent.on-event {:type :assistant-stream-end :final? true}))
  "side reply")

(fn make-runtime []
  (let [parent {:provider-name :mock
                :model "same-model"
                :messages [{:role :user :content "private parent context"}]}
        rt {:opts {:provider :mock :model "same-model"
                   :tools "bash,write" :active-tool-names {:bash true}}
            :agent parent}]
    (set rt.make-agent-from-opts
         (fn [opts on-event _extra]
           (set captured-opts opts)
           {:provider-name opts.provider
            :model opts.model
            :messages []
            :on-event on-event}))
    (set rt.submit-agent-turn!
         (fn [turn-state line opts emit]
           (turn-submit.submit! turn-state line opts agent-mod.step emit)))
    rt))

(fn reset! []
  (test-api.reset!)
  (tui-test.reset-state! {:cols 80 :rows 24})
  (set state.transcript [{:type :info :text "main untouched"}])
  (set state.input-buf "main draft")
  (set state.input-cursor (length state.input-buf))
  (set captured-opts nil)
  (set runtime (make-runtime))
  (set agent-mod.step fake-step)
  (tui.register (test-api.make-runtime-api :tui))
  (workspaces.ensure!))

(fn finish-side-turn! []
  (side-chat.tick!)
  (side-chat.tick!))

(describe "tui side chat"
  (fn []
    (before_each reset!)
    (after_each (fn [] (set agent-mod.step original-step)))

    (it "/btw creates the singleton tab with blank context and allowlisted tools"
      (fn []
        (let [ws (side-chat.open! runtime "first question")
              caps (workspaces.capabilities-for ws)]
          (assert.are.equal :btw ws.id)
          (assert.are.equal :side-chat ws.kind)
          (assert.are.equal "btw" ws.title)
          (assert.are.equal :ephemeral-side-chat ws.source.kind)
          (assert.are.equal :btw state.active-workspace-id)
          (assert.are.equal "btw> " (input.input-prompt))
          (assert.is_true caps.edit)
          (assert.is_true caps.input)
          (assert.is_false caps.submit)
          (assert.is_false caps.steer)
          (assert.are.equal "read,grep,find,ls" captured-opts.tools)
          (assert.is_nil captured-opts.denied-tools)
          (assert.is_false captured-opts.no-tools?)
          (assert.are.same {} captured-opts.active-tool-names)
          (assert.are.equal :mock ws.provider)
          (assert.are.equal "same-model" ws.model)
          ;; The private agent starts blank; its coroutine appends the first
          ;; user message only when the cooperative tick advances the turn.
          (assert.are.equal 0 (length ws.side.agent.messages))
          (side-chat.tick!)
          (assert.are.equal 1 (length ws.side.agent.messages))
          (assert.are.equal "first question" (. ws.side.agent.messages 1 :content))
          (assert.are.equal 1 (length runtime.agent.messages))
          (assert.are.equal "private parent context"
                            (. runtime.agent.messages 1 :content)))))

    (it "/btw dispatch creates and then focuses the existing tab"
      (fn []
        (command-registry.dispatch "/btw" runtime)
        (let [first (workspaces.find :btw)]
          (assert.is_truthy first)
          (workspaces.activate! :main-session)
          (command-registry.dispatch "/btw" runtime)
          (let [second (workspaces.find :btw)]
            (assert.is_true (rawequal first second))
            (assert.are.equal 2 (length (workspaces.list)))
            (assert.are.equal :btw state.active-workspace-id)))))

    (it "routes input and streamed transcript only to the side conversation"
      (fn []
        (let [ws (side-chat.open! runtime nil)
              main (workspaces.find :main-session)]
          (set state.input-buf "side question")
          (set state.input-cursor (length state.input-buf))
          (var parent-submits 0)
          (input.handle-key {:key tb.KEY_ENTER :ch 0 :mod 0}
                            (fn [_] (set parent-submits (+ parent-submits 1)))
                            nil (fn [] false))
          (assert.are.equal 0 parent-submits)
          (assert.are.equal "" state.input-buf)
          (assert.are.equal :user (. ws.transcript 1 :type))
          (assert.are.equal "side question" (. ws.transcript 1 :text))
          (finish-side-turn!)
          (assert.are.equal :idle ws.status)
          (assert.is_true (. (workspaces.capabilities-for ws) :submit))
          (assert.are.equal 2 (length ws.transcript))
          (assert.are.equal :assistant-text (. ws.transcript 2 :type))
          (assert.are.equal "side reply"
                            (transcript.event-text (. ws.transcript 2)))
          (assert.are.equal 9 ws.usage.total-tokens)
          (assert.are.equal 1 (length main.transcript))
          (assert.are.equal "main untouched" (. main.transcript 1 :text))
          (assert.are.equal 1 (length runtime.agent.messages)))))

    (it "/btw-use fills the main draft without submitting or changing focus"
      (fn []
        (let [ws (side-chat.open! runtime "question")]
          (finish-side-turn!)
          (assert.are.equal :btw state.active-workspace-id)
          (var parent-submits 0)
          (set state.input-buf "/btw-use")
          (set state.input-cursor (length state.input-buf))
          (input.handle-key
            {:key tb.KEY_ENTER :ch 0 :mod 0}
            (fn [line]
              (if (= (string.sub line 1 1) "/")
                  (command-registry.dispatch line runtime)
                  (set parent-submits (+ parent-submits 1))))
            nil (fn [] false))
          (assert.are.equal 0 parent-submits)
          (assert.are.equal :btw state.active-workspace-id)
          (assert.are.equal "" state.input-buf)
          (workspaces.activate! :main-session)
          (assert.are.equal "side reply" state.input-buf)
          (assert.are.equal (length "side reply") state.input-cursor)
          (assert.are.equal 1 (length state.transcript))
          (assert.are.equal "main untouched" (. state.transcript 1 :text))
          (assert.is_truthy ws))))

    (it "registers both side-chat commands idempotently"
      (fn []
        (var btw 0)
        (var use 0)
        (each [_ command (ipairs (command-registry.list))]
          (when (= command.name :btw) (set btw (+ btw 1)))
          (when (= command.name :btw-use) (set use (+ use 1))))
        (assert.are.equal 1 btw)
        (assert.are.equal 1 use)
        (tui.register (test-api.make-runtime-api :tui))
        (set btw 0)
        (set use 0)
        (each [_ command (ipairs (command-registry.list))]
          (when (= command.name :btw) (set btw (+ btw 1)))
          (when (= command.name :btw-use) (set use (+ use 1))))
        (assert.are.equal 1 btw)
        (assert.are.equal 1 use)))

    (it "ctrl-c cancels a busy side turn without arming quit"
      (fn []
        (let [ws (side-chat.open! runtime "question")]
          (side-chat.tick!)
          (var main-cancellations 0)
          (assert.is_false
            (input.handle-key {:key tb.KEY_CTRL_C :ch 0 :mod 0}
                              nil
                              (fn [] (set main-cancellations (+ main-cancellations 1)))
                              (fn [] false)))
          (assert.is_true ws.side.cancel-requested?)
          (assert.is_true ws.side.busy?)
          (assert.are.equal 0 main-cancellations)
          (assert.is_false state.pending-quit?)
          (assert.is_false state.cancel-pressed?))))

    (it "does not exit on double ctrl-c during a busy side turn"
      (fn []
        (let [ws (side-chat.open! runtime "question")]
          (side-chat.tick!)
          (assert.is_false
            (input.handle-key {:key tb.KEY_CTRL_C :ch 0 :mod 0}
                              nil nil (fn [] false)))
          (assert.is_false
            (input.handle-key {:key tb.KEY_CTRL_C :ch 0 :mod 0}
                              nil nil (fn [] false)))
          (assert.is_true ws.side.cancel-requested?)
          (assert.is_false state.pending-quit?)
          (assert.are.equal :btw state.active-workspace-id))))

    (it "ctrl-w cancels and discards all side state"
      (fn []
        (let [ws (side-chat.open! runtime "question")]
          (side-chat.tick!)
          (assert.is_true ws.side.busy?)
          (input.handle-key {:key tb.KEY_CTRL_W :ch 0 :mod 0}
                            nil nil (fn [] false))
          (assert.are.equal :main-session state.active-workspace-id)
          (assert.are.equal 1 (length (workspaces.list)))
          (assert.is_nil (workspaces.find :btw))
          (assert.is_nil ws.side)
          (assert.is_nil ws.agent)
          (assert.are.equal 1 (length runtime.agent.messages)))))

    (it "keeps workspace conversation state across behavior reloads"
      (fn []
        (let [ws (side-chat.open! runtime nil)
              old-workspaces (. package.loaded :fen.extensions.tui.workspaces)
              old-side (. package.loaded :fen.extensions.tui.side_chat)]
          (set state.input-buf "reload-safe side draft")
          (set state.input-cursor (length state.input-buf))
          (workspaces.capture-active!)
          (tset package.loaded :fen.extensions.tui.workspaces nil)
          (tset package.loaded :fen.extensions.tui.side_chat nil)
          (let [reloaded-workspaces (require :fen.extensions.tui.workspaces)
                reloaded-side (require :fen.extensions.tui.side_chat)
                found (reloaded-workspaces.find :btw)]
            (assert.is_true (rawequal ws found))
            (assert.is_true (rawequal ws.side.agent found.side.agent))
            (assert.are.equal "reload-safe side draft" found.input-buf)
            (reloaded-side.open! runtime nil)
            (assert.are.equal "reload-safe side draft" state.input-buf))
          (tset package.loaded :fen.extensions.tui.workspaces old-workspaces)
          (tset package.loaded :fen.extensions.tui.side_chat old-side))))))
