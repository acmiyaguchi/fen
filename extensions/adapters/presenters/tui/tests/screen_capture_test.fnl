;; Whole-frame TUI screen capture affordance tests.
;; The capture-enabled termbox stub lets story/golden tests assert composed
;; frames without opening a real terminal.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 24 :rows 6}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))

(fn reset! []
  (test-api.reset!)
  (set tb.width-value 24)
  (set tb.height-value 6)
  (tb.clear)
  (tui-test.reset-state! {:cols 24 :rows 6 :markdown? false})
  (tui.register (test-api.make-runtime-api :tui))
  (set state.tb-initialized? true)
  (paint.ensure-state-defaults!))

(describe "tui virtual screen capture"
  (fn []
    (before_each reset!)

    (it "captures paint-frame! text and cursor without a real terminal"
      (fn []
        (set state.input-buf "hello")
        (set state.input-cursor (length state.input-buf))
        (set state.transcript [{:type :info :text "hello transcript"}])
        (paint.paint-frame!)
        (let [lines (tui-test.screen-lines tb)]
          (assert.are.equal 6 (length lines))
          (assert.are.equal "hello transcript" (. lines 2))
          (assert.are.equal "> hello" (. lines 6)))
        (assert.are.equal 7 tb.cursor.x)
        (assert.are.equal 5 tb.cursor.y)
        (assert.is_false tb.cursor.hidden?)))

    (it "captures the last presented frame separately from the back buffer"
      (fn []
        (set state.input-buf "first")
        (set state.input-cursor (length state.input-buf))
        (paint.redraw!)
        (set state.input-buf "second")
        (set state.input-cursor (length state.input-buf))
        (paint.paint-frame!)
        (let [presented (tui-test.presented-screen-lines tb)
              current (tui-test.screen-lines tb)]
          (assert.are.equal "> first" (. presented 6))
          (assert.are.equal "> second" (. current 6)))))))
