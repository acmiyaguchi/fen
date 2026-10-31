;; Regression for #660 (spec/tui-turns, `ctrlCActsOnShownTurn`, `busyHintTruthful`):
;; on an idle btw tab or a running subagent tab, Ctrl-C never cancels or force-quits
;; the hidden main turn; on non-main tabs Ctrl-C clears the draft or arms a 2-press quit.

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

(describe "Ctrl-C on non-main tab (#660)"
          (fn []
            (before_each reset!)
            (after_each (fn []
                          (side-chat.reset!)
                          (run-state.reset!)
                          (tui-test.reset-state!)))
            (it "idle btw tab: first Ctrl-C clears draft, second arms quit, third quits; main is untouched"
                (fn []
                  (let [ws (side-chat.open! (runtime) nil)
                        main {:cancels 0}]
                    (assert.are.equal :btw state.active-workspace-id)
                    (assert.are.equal :idle ws.status)
                    (set state.input-buf "side draft")
                    (set state.input-cursor (length state.input-buf))
                    (let [row (busy-row)
                          quit1 (ctrl-c main)
                          cancels1 main.cancels
                          draft1 state.input-buf
                          quit2 (ctrl-c main)
                          cancels2 main.cancels
                          quit3 (ctrl-c main)]
                      ;; Idle tab has no busy row.
                      (assert.is_nil row)
                      ;; Press 1 clears the side draft; does not quit; does not touch main.
                      (assert.is_false quit1)
                      (assert.are.equal 0 cancels1)
                      (assert.are.equal "" draft1)
                      ;; Press 2 arms quit; does not touch main.
                      (assert.is_false quit2)
                      (assert.are.equal 0 cancels2)
                      (assert.is_true state.pending-quit?)
                      ;; Press 3 quits.
                      (assert.is_true quit3)
                      (assert.are.equal 0 main.cancels)))))
            (it "running subagent tab: busy row omits ctrl-c hint, and Ctrl-C does not touch main turn"
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
                    (assert.are.equal :running (. (workspaces.active) :status))
                    (let [row1 (busy-row)]
                      (assert.is_truthy row1 "subagent tab shows its busy row")
                      (assert.is_nil (string.find row1 "ctrl-c" 1 true))
                      (let [quit1 (ctrl-c main)
                            cancels1 main.cancels
                            row2 (busy-row)
                            quit2 (ctrl-c main)]
                        ;; Press 1 arms quit without touching main.
                        (assert.is_false quit1)
                        (assert.are.equal 0 cancels1)
                        (assert.is_true state.pending-quit?)
                        (assert.are.equal row1 row2)
                        ;; Press 2 quits without touching main.
                        (assert.is_true quit2)
                        (assert.are.equal 0 main.cancels))))))))
