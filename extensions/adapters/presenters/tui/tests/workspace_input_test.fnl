;; Read-only workspace keyboard boundary.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(tui-test.install-markdown-stub!)

(local state (require :fen.extensions.tui.state))
(local workspaces (require :fen.extensions.tui.workspaces))
(local input (require :fen.extensions.tui.input))

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
  (workspaces.ensure!)
  (table.insert state.workspaces {:id :job :kind :subagent-job :title "job"
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
          (assert.are.equal "draft" state.input-buf)
          (assert.are.equal 5 state.input-cursor)
          (assert.is_false submitted?))))

    (it "does not move the main draft cursor or history from a subagent workspace"
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
        (assert.are.equal "draft" state.input-buf)
        (assert.are.equal 5 state.input-cursor)
        (assert.are.equal 0 state.history-pos)))))
