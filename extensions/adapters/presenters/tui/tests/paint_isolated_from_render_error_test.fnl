;; Regression for #635 (spec/scheduler, `loopSurvivesFaults`): a transcript row
;; that fails to render is caught with per-row error isolation, displaying
;; an error placeholder rather than crashing the loop.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub!))
(local default-peek tb.peek_event)

(local ext-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))

(tui.register (ext-api.make-runtime-api :tui))

(local NO-EVENT-PEEKS 3)
(local MAX-PEEKS 20)

(fn run-loop! []
  "Drive the real M.run: NO-EVENT-PEEKS idle peeks, then Ctrl-D. Returns
   ok?, err, on-tick count, and peeks consumed."
  (var peeks 0)
  (var ticks 0)
  (set tb.peek_event
       (fn [_timeout]
         (set peeks (+ peeks 1))
         (if (or (> peeks NO-EVENT-PEEKS) (> peeks MAX-PEEKS))
             {:type tb.EVENT_KEY :key tb.KEY_CTRL_D :ch 0 :mod 0}
             (values nil "no event" tb.ERR_NO_EVENT))))
  (let [(ok? err) (pcall tui.run (fn [_line] nil)
                         (fn [] (set ticks (+ ticks 1))) (fn [] nil)
                         (fn []
                           false))]
    (values ok? err ticks peeks)))

(describe "unguarded transcript paint (#635)"
          (fn []
            (before_each (fn []
                           (tui-test.reset-state!)
                           (set state.tb-initialized? true)
                           (set state.dirty? true)))
            (after_each (fn []
                          (set tb.peek_event default-peek)
                          (set state.tb-initialized? false)
                          (tui-test.reset-state!)))
            (it "a non-string :info text renders an error row and loop exits cleanly on Ctrl-D"
                (fn []
                  ;; Real bus -> real TUI subscriber -> state.transcript.
                  (events.emit {:type :info :text 42})
                  (let [last (. state.transcript (length state.transcript))]
                    (assert.are.equal :info last.type)
                    (assert.are.equal 42 last.text))
                  (let [(ok? err ticks peeks) (run-loop!)]
                    (assert.is_true ok? (tostring err))
                    (assert.are.equal NO-EVENT-PEEKS ticks)
                    (assert.are.equal (+ NO-EVENT-PEEKS 1) peeks))))))
