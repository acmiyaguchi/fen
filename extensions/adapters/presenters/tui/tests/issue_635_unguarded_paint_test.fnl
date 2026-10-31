;; Known bug #635: a transcript row that cannot render raises out of the unguarded paint phase and ends M.run.

(local {: known-bug} (require :fen.testing))
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

(describe "#635 unguarded transcript paint"
          (fn []
            (before_each (fn []
                           (tui-test.reset-state!)
                           (set state.tb-initialized? true)
                           (set state.dirty? true)))
            (after_each (fn []
                          (set tb.peek_event default-peek)
                          (set state.tb-initialized? false)
                          (tui-test.reset-state!)))
            (it "a non-string :info text raises out of M.run instead of rendering an error row"
                (fn []
                  (known-bug 635
                             (fn []
                               ;; Control: a well-formed row paints and the loop exits on Ctrl-D.
                               (events.emit {:type :info :text "fine"})
                               (let [(ctl-ok? _ ctl-ticks ctl-peeks) (run-loop!)]
                                 (assert.is_true ctl-ok?
                                                 "control run must exit cleanly")
                                 (assert.are.equal NO-EVENT-PEEKS ctl-ticks)
                                 (assert.are.equal (+ NO-EVENT-PEEKS 1)
                                                   ctl-peeks))
                               (tui-test.reset-state!)
                               (set state.tb-initialized? true)
                               (set state.dirty? true)
                               ;; Real bus -> real TUI subscriber -> state.transcript.
                               (events.emit {:type :info :text 42})
                               (let [last (. state.transcript
                                             (length state.transcript))]
                                 (assert.are.equal :info last.type)
                                 (assert.are.equal 42 last.text))
                               (let [(ok? err ticks peeks) (run-loop!)]
                                 (and (= ok? false) (= ticks 0) (= peeks 0)
                                      (not= nil
                                            (string.find (tostring err)
                                                         "transcript.fnl" 1 true))))))))))
