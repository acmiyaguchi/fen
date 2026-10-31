;; Known bug #660: on an idle btw tab or a running subagent tab, Ctrl-C walks the main-session ladder (cancel, then force-quit) for a main turn the user cannot see, and the busy row gives no hint.

(local {: known-bug} (require :fen.testing))
(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(tui-test.install-markdown-stub!)

(local state (require :fen.extensions.tui.state))
(local workspaces (require :fen.extensions.tui.workspaces))
(local side-chat (require :fen.extensions.tui.side_chat))
(local input (require :fen.extensions.tui.input))
(local busy (require :fen.extensions.tui.panels.busy))
(local run-state (require :fen.extensions.subagent.runs))

(fn runtime []
  {:opts {:provider :mock :model "m"}
   :agent {:provider-name :mock :model "m" :messages []}
   :make-agent-from-opts (fn [opts on-event _extra]
                           {:provider-name opts.provider
                            :model opts.model
                            :messages []
                            : on-event})})

(fn reset! []
  (side-chat.reset!)
  (run-state.reset!)
  (tui-test.reset-state! {:cols 80 :rows 24})
  (set state.api {:emit (fn [_]) :ui {:select (fn [_] nil)}})
  (workspaces.ensure!))

(fn ctrl-c [main]
  "Real handle-key Ctrl-C with the main session busy; counts main cancels."
  (input.handle-key {:key tb.KEY_CTRL_C :ch 0 :mod 0} nil
                    (fn []
                      (set main.cancels (+ main.cancels 1)))
                    (fn []
                      true)))

(fn busy-row []
  (let [rows (busy.render {:w 80})]
    (if (= (length rows) 0) nil (. rows 1 :text))))

(describe "#660 Ctrl-C on a side or subagent tab acts on the hidden main turn"
          (fn []
            (before_each reset!)
            (after_each (fn []
                          (side-chat.reset!)
                          (run-state.reset!)
                          (tui-test.reset-state!)))
            (it "idle btw tab: first Ctrl-C cancels main, second quits, no busy row warns"
                (fn []
                  (known-bug 660
                             (fn []
                               (let [ws (side-chat.open! (runtime) nil)
                                     main {:cancels 0}]
                                 (assert.are.equal :btw
                                                   state.active-workspace-id)
                                 (assert.are.equal :idle ws.status)
                                 (set state.input-buf "side draft")
                                 (set state.input-cursor
                                      (length state.input-buf))
                                 (let [row (busy-row)
                                       quit1 (ctrl-c main)
                                       cancels1 main.cancels
                                       draft1 state.input-buf
                                       quit2 (ctrl-c main)]
                                   ;; Bug: no busy row, yet press 1 cancels main (draft kept) and press 2 exits fen.
                                   (and (= row nil) (= quit1 false)
                                        (= cancels1 1) (= draft1 "side draft")
                                        (= quit2 true))))))))
            (it "running subagent tab: busy row omits the hint, yet Ctrl-C cancels main then quits"
                (fn []
                  (known-bug 660
                             (fn []
                               (let [run (run-state.start! {:agent "reviewer"
                                                            :task "review"
                                                            :cwd "/tmp"
                                                            :background? true})
                                     id (.. "subagent:" run.id)
                                     main {:cancels 0}]
                                 (run-state.append-event! run.id
                                                          {:type :tool-call
                                                           :id "c1"
                                                           :name :bash
                                                           :arguments {:command "sleep 9"}})
                                 (workspaces.sync-subagents!)
                                 (workspaces.activate! id)
                                 (assert.are.equal :running
                                                   (. (workspaces.active)
                                                      :status))
                                 (let [row1 (busy-row)
                                       quit1 (ctrl-c main)
                                       cancels1 main.cancels
                                       row2 (busy-row)
                                       quit2 (ctrl-c main)]
                                   (assert.is_truthy row1
                                                     "subagent tab shows its busy row")
                                   ;; Bug: the row never mentions ctrl-c, but press 1 cancels the main turn and press 2 exits fen.
                                   (and (= nil
                                           (string.find row1 "ctrl-c" 1 true))
                                        (= quit1 false) (= cancels1 1)
                                        (= row2 row1) (= quit2 true))))))))))
