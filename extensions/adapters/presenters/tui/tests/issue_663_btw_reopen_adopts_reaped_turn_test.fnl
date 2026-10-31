;; Known bug #663: reopening /btw while a closed tab's slow-to-unwind turn is still being reaped hands the new tab the old live entry: it shows idle but rejects submits as busy, and the old turn's late reply lands in its transcript.

(local {: known-bug} (require :fen.testing))
(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local command-registry (require :fen.core.extensions.register.command))
(local agent-mod (require :fen.core.agent))
(local turn-submit (require :fen.turn_submit))
(local original-step agent-mod.step)
(local state (require :fen.extensions.tui.state))
(local original-presenter-ctx state.presenter-ctx)
(local workspaces (require :fen.extensions.tui.workspaces))
(local side-chat (require :fen.extensions.tui.side_chat))
(local input (require :fen.extensions.tui.input))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local tui (require :fen.extensions.tui))

;; More than side_chat's CANCEL-RESUME-LIMIT (8), so close must park the turn for reaping.
(local UNWIND-YIELDS 12)

(fn slow-step [agent prompt _cancel]
  "Fake agent.step that ignores cancel and needs UNWIND-YIELDS resumes, then
   replies through the agent's own on-event."
  (table.insert agent.messages {:role :user :content prompt})
  (for [_ 1 UNWIND-YIELDS]
    (coroutine.yield))
  (let [text (.. "late reply to: " prompt)]
    (table.insert agent.messages
                  {:role :assistant
                   :content [{:type :text : text}]
                   :stop-reason :stop})
    (agent.on-event {:type :assistant-text : text})
    text))

(fn make-runtime []
  {:opts {:provider :mock :model "m"}
   :agent {:provider-name :mock :model "m" :messages []}
   :make-agent-from-opts (fn [opts on-event _extra]
                           {:provider-name opts.provider
                            :model opts.model
                            :messages []
                            : on-event})
   :submit-agent-turn! (fn [turn-state line opts emit]
                         (turn-submit.submit! turn-state line opts
                                              agent-mod.step emit))})

(fn reset! []
  (side-chat.reset!)
  (test-api.reset!)
  (tui-test.reset-state! {:cols 80 :rows 24})
  (set agent-mod.step slow-step)
  (tui.register (test-api.make-runtime-api :tui))
  (workspaces.ensure!))

(fn late-reply-rows [ws]
  (let [out []]
    (each [_ row (ipairs ws.transcript)]
      (when (and (= row.type :assistant-text)
                 (= (transcript.event-text row) "late reply to: old question"))
        (table.insert out row)))
    out))

(describe "#663 reopened /btw adopts the closed tab's still-reaping turn"
          (fn []
            (before_each reset!)
            (after_each (fn []
                          (set agent-mod.step original-step)
                          (set state.presenter-ctx original-presenter-ctx)
                          (side-chat.reset!)
                          (test-api.reset!)
                          (tui-test.reset-state!)))
            (it "new tab shows idle but is busy, and the old turn's reply lands in it"
                (fn []
                  (known-bug 663
                             (fn []
                               (let [runtime (make-runtime)
                                     _ (set state.presenter-ctx
                                            {:state runtime})
                                     old (side-chat.open! runtime nil)]
                                 (let [started (side-chat.submit! old
                                                                  "old question")]
                                   (assert.is_true started.ok
                                                   (tostring started.error)))
                                 (side-chat.tick!)
                                 (assert.are.equal :running old.status)
                                 ;; Ctrl-W while running: the bounded drain cannot finish, so the turn is parked.
                                 (input.handle-key {:key tb.KEY_CTRL_W
                                                    :ch 0
                                                    :mod 0}
                                                   nil nil
                                                   (fn []
                                                     false))
                                 (assert.is_nil (workspaces.find :btw))
                                 (assert.are.equal :closed old.status)
                                 (command-registry.dispatch "/btw" runtime)
                                 (let [new (workspaces.find :btw)
                                       idle? (and (not (rawequal new old))
                                                  (= new.status :idle)
                                                  (= new.side.busy? false))
                                       early (side-chat.submit! new
                                                                "new question")]
                                   ;; Enough presenter ticks to finish any one turn.
                                   (for [_ 0 UNWIND-YIELDS]
                                     (side-chat.tick!))
                                   (let [late (late-reply-rows new)
                                         after (side-chat.submit! new
                                                                  "after reap")]
                                     ;; Not part of the bug: the busy rejection clears once the reap finishes (the live presenter runtime rebuilds the agent).
                                     (assert.is_true after.ok
                                                     (tostring after.error))
                                     ;; Bug: idle-looking tab rejects as busy, then receives the old turn's reply.
                                     (and idle? (= early.ok false)
                                          (= early.error "side agent is busy")
                                          (= (length late) 1)))))))))))
