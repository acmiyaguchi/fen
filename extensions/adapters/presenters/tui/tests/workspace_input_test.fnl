;; Read-only workspace keyboard boundary.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(tui-test.install-markdown-stub!)

(local state (require :fen.extensions.tui.state))
(local workspaces (require :fen.extensions.tui.workspaces))
(local input (require :fen.extensions.tui.input))
(local run-state (require :fen.extensions.subagent.state))

(fn reset! []
  (set state.workspaces [])
  (set state.active-workspace-id :main-session)
  (set state.transcript [])
  (set state.streaming-assistant-rows {})
  (set state.transcript-layout-cache nil)
  (set state.scroll-offset 0)
  (set state.new-content-below? false)
  (set state.last-user-jump-index nil)
  (set state.selection nil)
  (set state.selection-paint nil)
  (set state.input-buf "draft")
  (set state.input-cursor 5)
  (set state.paste-active? false)
  (set state.paste-buffer "")
  (set state.pastes {})
  (set state.history [])
  (set state.history-pos 0)
  (set state.history-draft "")
  (set state.pending-quit? false)
  (set state.alt-pending? false)
  (set state.cancel-pressed? false)
  (set state.closed-subagent-workspaces {})
  (set state.api {:emit (fn [_])
                  :ui {:select (fn [_] nil)}})
  (workspaces.ensure!)
  (table.insert state.workspaces {:id :job :kind :projection :title "job"
                                  :capabilities {:edit false :submit false}
                                  :transcript [] :streaming-assistant-rows {}
                                  :transcript-layout-cache nil :scroll-offset 0
                                  :new-content-below? false :last-user-jump-index nil
                                  :selection nil :selection-paint nil})
  (workspaces.activate! :job))

(describe "read-only workspace input"
  (fn []
    (before_each reset!)

    (it "does not edit or submit from a subagent workspace"
      (fn []
        (var submitted? false)
        (let [submit (fn [_] (set submitted? true))]
          (input.handle-key {:key 0 :ch (string.byte "x") :utf8 "x" :mod 0}
                            submit nil (fn [] false))
          (input.handle-key {:key tb.KEY_CTRL_J :ch 0 :mod 0}
                            submit nil (fn [] false))
          (input.handle-key {:key tb.KEY_ENTER :ch 0 :mod 0}
                            submit nil (fn [] false))
          (assert.are.equal "" state.input-buf)
          (assert.are.equal 0 state.input-cursor)
          (assert.is_false submitted?)
          (workspaces.activate! :main-session)
          (assert.are.equal "draft" state.input-buf)
          (assert.are.equal 5 state.input-cursor))))

    (it "does not move the main draft cursor or history from a read-only workspace"
      (fn []
        (set state.history ["previous draft"])
        (input.handle-key {:key tb.KEY_ARROW_LEFT :ch 0 :mod 0}
                          nil nil (fn [] false))
        (input.handle-key {:key tb.KEY_ARROW_RIGHT :ch 0 :mod 0}
                          nil nil (fn [] false))
        (input.handle-key {:key tb.KEY_ARROW_UP :ch 0 :mod 0}
                          nil nil (fn [] false))
        (input.handle-key {:key tb.KEY_ARROW_DOWN :ch 0 :mod 0}
                          nil nil (fn [] false))
        (input.handle-key {:key tb.KEY_CTRL_C :ch 0 :mod 0}
                          nil nil (fn [] false))
        (assert.are.equal "" state.input-buf)
        (assert.are.equal 0 state.input-cursor)
        (assert.are.equal 0 state.history-pos)
        (workspaces.activate! :main-session)
        (assert.are.equal "draft" state.input-buf)
        (assert.are.equal 5 state.input-cursor)))

    (it "routes next, previous, and list keys through workspace focus"
      (fn []
        ;; The fixture starts on :job.
        (input.handle-key {:key tb.KEY_ARROW_RIGHT :ch 0 :mod tb.MOD_ALT}
                          nil nil (fn [] false))
        (assert.are.equal :main-session state.active-workspace-id)
        (input.handle-key {:key tb.KEY_ARROW_LEFT :ch 0 :mod tb.MOD_ALT}
                          nil nil (fn [] false))
        (assert.are.equal :job state.active-workspace-id)
        (var selector-label nil)
        (set state.api.ui.select
             (fn [opts]
               (set selector-label opts.label)
               {:value :main-session}))
        (input.handle-key {:key 0 :ch (string.byte "t") :mod tb.MOD_ALT}
                          nil nil (fn [] false))
        (assert.are.equal "tabs" selector-label)
        (assert.are.equal :main-session state.active-workspace-id)))

    (it "routes a running subagent draft only to steering"
      (fn []
        (run-state.reset!)
        (set state.workspaces [])
        (set state.active-workspace-id :main-session)
        (set state.transcript [])
        (set state.input-buf "main draft")
        (set state.input-cursor 10)
        (workspaces.ensure!)
        (let [run (run-state.start! {:agent "reviewer" :task "review"
                                     :cwd "/tmp" :background? true})]
          (workspaces.sync-subagents!)
          (workspaces.activate! "subagent:subagent-1")
          (assert.are.equal "Steer> " (input.input-prompt))
          (var parent-submitted? false)
          (each [_ ch (ipairs ["f" "o" "c" "u" "s"])]
            (input.handle-key {:key 0 :ch (string.byte ch) :utf8 ch :mod 0}
                              (fn [_] (set parent-submitted? true)) nil
                              (fn [] false)))
          (input.handle-key {:key tb.KEY_ENTER :ch 0 :mod 0}
                            (fn [_] (set parent-submitted? true)) nil
                            (fn [] false))
          (assert.is_false parent-submitted?)
          (assert.are.equal "" state.input-buf)
          (let [stored (run-state.find run.id)]
            (assert.are.equal 1 (length stored.steering-notes))
            (assert.are.equal "focus" (. stored.steering-notes 1 :note)))
          (workspaces.activate! :main-session)
          (assert.are.equal "main draft" state.input-buf))))

    (it "keeps a rejected steering draft and shows the reason in its tab"
      (fn []
        (run-state.reset!)
        (set state.workspaces [])
        (set state.active-workspace-id :main-session)
        (set state.transcript [])
        (workspaces.ensure!)
        (let [run (run-state.start! {:agent "reviewer" :task "review"
                                     :cwd "/tmp" :background? true})]
          (workspaces.sync-subagents!)
          (workspaces.activate! "subagent:subagent-1")
          (set state.input-buf "late steering note")
          (set state.input-cursor (length state.input-buf))
          ;; Leave the projected tab steerable to model a run finishing between
          ;; the last presenter tick and this Enter key.
          (run-state.finish! run.id :completed {:result "done"})
          (input.handle-key {:key tb.KEY_ENTER :ch 0 :mod 0}
                            nil nil (fn [] false))
          (assert.are.equal "late steering note" state.input-buf)
          (assert.are.equal (length state.input-buf) state.input-cursor)
          (let [last (. state.transcript (length state.transcript))]
            (assert.are.equal :error last.type)
            (assert.are.equal "subagent run is not active: subagent-1"
                              last.error)))))

    (it "closes the active subagent tab with ctrl-w and restores main"
      (fn []
        (table.insert state.workspaces
                      {:id "subagent:subagent-1" :kind :subagent-job
                       :title "scout subagent-1"
                       :capabilities {:edit false :submit false}
                       :transcript [] :streaming-assistant-rows {}
                       :transcript-layout-cache nil :scroll-offset 0
                       :new-content-below? false :last-user-jump-index nil
                       :selection nil :selection-paint nil})
        (workspaces.activate! "subagent:subagent-1")
        (input.handle-key {:key tb.KEY_CTRL_W :ch 0 :mod 0}
                          nil nil (fn [] false))
        (assert.are.equal :main-session state.active-workspace-id)
        (assert.is_true (. state.closed-subagent-workspaces "subagent:subagent-1"))
        (var present? false)
        (each [_ ws (ipairs state.workspaces)]
          (when (= ws.id "subagent:subagent-1") (set present? true)))
        (assert.is_false present?)))

    (it "leaves ctrl-w as delete-word-back on the main draft"
      (fn []
        (workspaces.activate! :main-session)
        (set state.input-buf "hello world")
        (set state.input-cursor (length state.input-buf))
        (input.handle-key {:key tb.KEY_CTRL_W :ch 0 :mod 0}
                          nil nil (fn [] false))
        (assert.are.equal "hello " state.input-buf)))))
