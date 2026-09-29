;; Contextual hints in existing regions: idle input placeholder, busy-row cancel action, scrolled-status recovery key.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 10}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local input (require :fen.extensions.tui.input))
(local workspaces (require :fen.extensions.tui.workspaces))
(local events (require :fen.core.extensions.events))

;; Record print attributes so dim styling is observable, not just text.
(local prints [])
(local stub-print tb.print)
(set tb.print (fn [x y fg bg text]
                (table.insert prints {: x : y : fg : text})
                (stub-print x y fg bg text)))

(fn reset! [?cols ?rows]
  (let [cols (or ?cols 80)
        rows (or ?rows 10)]
    (test-api.reset!)
    (set tb.width-value cols)
    (set tb.height-value rows)
    (tb.clear)
    (tui-test.reset-state! {:cols cols :rows rows :markdown? false})
    (tui.register (test-api.make-runtime-api :tui))
    (set state.tb-initialized? true)
    (set state.pending-quit? false)
    (set state.cancel-pressed? false)
    (set state.new-content-below? false)
    (paint.ensure-state-defaults!)
    (set state.status-info.running-label nil)
    (set state.status-info.thinking? false)
    (set state.status-info.cancelling? false)
    (set state.status-info.turn-start 0)))

(fn frame []
  (for [i (length prints) 1 -1] (table.remove prints i))
  (tb.clear)
  (paint.paint-frame!)
  (tui-test.screen-lines tb))

(fn last-line [lines]
  (. lines (length lines)))

(fn press! [ev ?is-busy? ?on-cancel]
  (input.handle-key ev (fn [_]) ?on-cancel ?is-busy?))

(fn type! [text]
  (each [c (string.gmatch text ".")]
    (press! {:key 0 :ch (string.byte c) :utf8 c :mod 0})))

(fn print-at [y x]
  (var found nil)
  (each [_ p (ipairs prints)]
    (when (and (= p.y y) (= p.x x))
      (set found p)))
  found)

(describe "idle input placeholder"
          (fn []
            (it "shows a dim command hint after the prompt while the input is empty"
                (fn []
                  (reset! 80 10)
                  (let [lines (frame)
                        hint (print-at 9 2)]
                    (assert.are.equal "> type / for commands · /help for keys · ctrl-j newline"
                                      (last-line lines))
                    (assert.is_truthy hint
                                      "placeholder painted at the prompt edge")
                    (assert.are.equal (bor tb.WHITE tb.DIM) hint.fg)
                    ;; The cursor stays at the prompt edge; the hint is not buffer text.
                    (assert.are.equal 2 tb.cursor.x)
                    (assert.are.equal "" state.input-buf))))
            (it "shortens on narrow terminals and clips instead of wrapping"
                (fn []
                  (reset! 40 6)
                  (assert.are.equal "> / for commands" (last-line (frame)))
                  (reset! 10 6)
                  (let [lines (frame)]
                    (assert.are.equal "> / for co" (last-line lines))
                    (assert.are.equal 1 (input.input-rows)))))
            (it "disappears on the first keystroke and returns when ctrl-c clears the draft"
                (fn []
                  (reset! 80 10)
                  (type! "hi")
                  (assert.are.equal "> hi" (last-line (frame)))
                  (press! {:key tb.KEY_CTRL_C :ch 0 :mod 0}
                          (fn []
                            false))
                  (assert.are.equal "" state.input-buf)
                  (assert.is_false state.pending-quit?)
                  (assert.is_truthy (string.find (last-line (frame))
                                                 "type / for commands" 1 true))))
            (it "omits command hints in the side-chat editor where slash input is literal"
                (fn []
                  (reset! 80 10)
                  (let [ws (workspaces.create! {:id :btw
                                                :kind :side-chat
                                                :title "btw"})]
                    (workspaces.activate! ws.id)
                    (assert.are.equal "btw>" (last-line (frame)))
                    (workspaces.activate! :main-session)
                    (assert.is_truthy (string.find (last-line (frame))
                                                   "/ for commands" 1 true)))))))

(describe "busy row cancel hint"
          (fn []
            (it "names the ctrl-c action, then the force-quit after cancel is requested"
                (fn []
                  (reset! 80 10)
                  (set state.status-info.running-label "$ make test")
                  (let [busy (fn []
                               true)
                        cancels []
                        lines (frame)]
                    (assert.are.equal "  ⠋ $ make test · ctrl-c cancel"
                                      (. lines 9))
                    (press! {:key tb.KEY_CTRL_C :ch 0 :mod 0} busy
                            (fn [] (table.insert cancels true)))
                    (assert.are.equal 1 (length cancels))
                    (assert.are.equal "  ⠋ $ make test · ctrl-c again quit"
                                      (. (frame) 9)))))
            (it "drops the hint rather than clipping the busy label on narrow terminals"
                (fn []
                  (reset! 24 6)
                  (set state.status-info.running-label "$ make test")
                  (assert.are.equal "  ⠋ $ make test" (. (frame) 5))))
            (it "does not offer ctrl-c cancel on a running subagent tab it cannot cancel"
                (fn []
                  (reset! 80 10)
                  (let [ws (workspaces.create! {:id :job
                                                :kind :subagent-job
                                                :title "scout"
                                                :status :running
                                                :status-info {:thinking? true}})]
                    (workspaces.activate! ws.id)
                    (let [lines (frame)]
                      (assert.are.equal "  ⠋ thinking" (. lines 9))
                      (assert.are.equal "Steer>" (last-line lines))))))))

(describe "scrolled status recovery hint"
          (fn []
            (it "names ctrl-y while scrolled and clears after returning to the live bottom"
                (fn []
                  (reset! 80 10)
                  (for [i 1 30]
                    (table.insert state.transcript
                                  {:type :info :text (.. "line " i)}))
                  (press! {:key tb.KEY_PGUP :ch 0 :mod 0})
                  (let [n state.scroll-offset]
                    (assert.is_true (> n 0))
                    (assert.is_truthy (string.find (. (frame) 1)
                                                   (.. "↑" n
                                                       " · ctrl-y bottom")
                                                   1 true))
                    (set state.new-content-below? true)
                    (assert.is_truthy (string.find (. (frame) 1)
                                                   (.. "↑" n
                                                       " ↓new · ctrl-y")
                                                   1 true)))
                  (press! {:key 0x19 :ch 0 :mod 0})
                  (assert.are.equal 0 state.scroll-offset)
                  (assert.is_nil (string.find (. (frame) 1) "ctrl-y" 1 true))))
            (it "keeps the recovery key visible when long left-side status items overflow a narrow row"
                (fn []
                  (reset! 60 10)
                  ((. (test-api.make-runtime-api :probe) :register) :status
                                                                    {:name :long-left
                                                                     :side :left
                                                                     :order 5
                                                                     :render (fn [_]
                                                                               {:text (string.rep "m"
                                                                                                  60)
                                                                                :style :status})})
                  (for [i 1 30]
                    (table.insert state.transcript
                                  {:type :info :text (.. "line " i)}))
                  (press! {:key tb.KEY_PGUP :ch 0 :mod 0})
                  (let [top (. (frame) 1)
                        hint (.. "↑" state.scroll-offset " · ctrl-y bottom")]
                    (assert.is_truthy (string.find top hint 1 true))
                    ;; Columns, not bytes: the multibyte arrow must not widen the separator
                    ;; before the next right-side item.
                    (assert.is_truthy (string.find top "ctrl%-y bottom  %S")))))))

(describe "contextual idle hint"
          (fn []
            (local HINT "topic changed · /handoff")

            (fn suggest! [?key]
              (events.emit {:type :hint
                            :text HINT
                            :key (or ?key "handoff/topic-shift:a")}))

            (fn shows-hint? []
              (= (.. "> " HINT) (last-line (frame))))

            (fn shows-default? []
              (not= nil (string.find (last-line (frame)) "type / for commands"
                                     1 true)))

            (it "replaces the default placeholder, dim and outside the buffer, never as a transcript row"
                (fn []
                  (reset! 80 10)
                  (suggest!)
                  (let [lines (frame)]
                    (assert.are.equal (.. "> " HINT) (last-line lines))
                    (assert.are.equal (bor tb.WHITE tb.DIM)
                                      (. (print-at 9 2) :fg))
                    (assert.are.equal "" state.input-buf)
                    (assert.are.equal 0 (length state.transcript)))))
            (it "clips to narrow terminals without wrapping"
                (fn []
                  (reset! 12 6)
                  (suggest!)
                  (assert.are.equal "> topic chan" (last-line (frame)))
                  (assert.are.equal 1 (input.input-rows))))
            (it "disappears on the first edit and does not come back when the draft is cleared"
                (fn []
                  (reset! 80 10)
                  (suggest!)
                  (type! "x")
                  (assert.are.equal "> x" (last-line (frame)))
                  (press! {:key tb.KEY_BACKSPACE2 :ch 0 :mod 0})
                  (assert.is_true (shows-default?))))
            (it "disappears after running the suggested command"
                (fn []
                  (reset! 80 10)
                  (suggest!)
                  (let [submitted []]
                    (type! "/handoff")
                    (input.handle-key {:key tb.KEY_ENTER :ch 0 :mod 0}
                                      (fn [line] (table.insert submitted line))
                                      nil
                                      (fn []
                                        false))
                    (assert.are.same ["/handoff"] submitted)
                    (assert.is_true (shows-default?)))))
            (it "dismisses on Esc and on a conversation reset"
                (fn []
                  (reset! 80 10)
                  (suggest!)
                  (press! {:key tb.KEY_ESC :ch 0 :mod 0})
                  ;; The run loop's idle tick turns a bare Esc into :dismiss.
                  (events.emit {:type :dismiss})
                  (assert.is_true (shows-default?))
                  (suggest! "handoff/topic-shift:b")
                  (assert.is_true (shows-hint?))
                  (events.emit {:type :reset-conversation})
                  (assert.is_true (shows-default?))))
            (it "never shows the same key twice, while a new key still appears"
                (fn []
                  (reset! 80 10)
                  (suggest! "k1")
                  (events.emit {:type :dismiss})
                  (suggest! "k1")
                  (assert.is_true (shows-default?))
                  (suggest! "k2")
                  (assert.is_true (shows-hint?))))
            (it "drops a hint that arrives after the user started typing"
                (fn []
                  (reset! 80 10)
                  (type! "draft")
                  (suggest!)
                  (assert.are.equal "> draft" (last-line (frame)))
                  (press! {:key tb.KEY_CTRL_U :ch 0 :mod 0})
                  (assert.are.equal "" state.input-buf)
                  (assert.is_true (shows-default?))))
            (it "stays out of the side-chat editor and returns on the main tab"
                (fn []
                  (reset! 80 10)
                  (suggest!)
                  (let [ws (workspaces.create! {:id :btw
                                                :kind :side-chat
                                                :title "btw"})]
                    (workspaces.activate! ws.id)
                    (assert.are.equal "btw>" (last-line (frame)))
                    (workspaces.activate! :main-session)
                    (assert.is_true (shows-hint?)))))
            (it "drops a hint that arrives while another tab is active, even if that tab's draft is empty"
                (fn []
                  (reset! 80 10)
                  (type! "main draft")
                  (let [ws (workspaces.create! {:id :btw
                                                :kind :side-chat
                                                :title "btw"})]
                    (workspaces.activate! ws.id)
                    (assert.are.equal "" state.input-buf)
                    (suggest!)
                    ;; Not accepted (and its key not spent) while the main editor is not active.
                    (assert.is_nil state.input-hint)
                    (workspaces.activate! :main-session)
                    (press! {:key tb.KEY_CTRL_U :ch 0 :mod 0})
                    (assert.are.equal "" state.input-buf)
                    (assert.is_true (shows-default?)))))))
