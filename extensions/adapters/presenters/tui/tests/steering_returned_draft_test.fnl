;; #662 hand-back as the TUI user sees it: steering typed while the main turn
;; runs, which the turn ends without reading, comes back into the main draft
;; (in front of anything typed since) with a transcript notice, instead of
;; being dropped or injected into the next turn.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 12}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local input-pipeline (require :fen.core.extensions.input))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local input (require :fen.extensions.tui.input))
(local tasks (require :fen.core.tasks))
(local steering-ext (require :fen.extensions.steering))

(local run {:busy? true})

(fn on-submit [line]
  (input-pipeline.handle {:kind :user-input :text line}
                         {:busy? run.busy? :state run}))

(fn type-text! [text]
  (each [c (string.gmatch text ".")]
    (input.handle-key {:key 0 :ch (string.byte c) :utf8 c :mod 0} on-submit nil
                      (fn [] run.busy?))))

(fn press-enter! []
  (input.handle-key {:key tb.KEY_ENTER :ch 0 :mod 0} on-submit nil
                    (fn [] run.busy?)))

(fn frame []
  (tb.clear)
  (paint.paint-frame!)
  (tui-test.screen-text tb))

(fn reset! []
  (test-api.reset!)
  (tasks.reset!)
  (set run.busy? true)
  (tb.clear)
  (tui-test.reset-state! {:cols 80 :rows 12 :markdown? false})
  (tui.register (test-api.make-runtime-api :tui))
  (steering-ext.register (test-api.make-runtime-api :steering))
  (set state.tb-initialized? true)
  (paint.ensure-state-defaults!))

(describe "steering returned to the TUI draft (#662)"
          (fn []
            (before_each reset!)
            (after_each (fn [] (tasks.reset!) (test-api.reset!)))
            (it "puts unread steering back in front of the current draft"
                (fn []
                  (let [(_ hid) (tasks.spawn-holder :turn #(coroutine.yield))]
                    (type-text! "fix the tests too")
                    (press-enter!)
                    (assert.are.equal 1 (. (tasks.info) :steering-queued))
                    (assert.are.equal "" state.input-buf)
                    (type-text! "and docs")
                    ;; The turn errors before its next boundary.
                    (tasks.release! hid)
                    (set run.busy? false)
                    (assert.are.equal "fix the tests too\nand docs"
                                      state.input-buf)
                    (assert.are.equal (length "fix the tests too")
                                      state.input-cursor)
                    (assert.are.equal 0 (. (tasks.info) :steering-queued))
                    (assert.is_truthy (string.find (frame) "steering returned"
                                                   1 true)))))
            (it "leaves the draft alone when the turn read every line"
                (fn []
                  (let [(_ hid) (tasks.spawn-holder :turn #(coroutine.yield))]
                    (type-text! "steer")
                    (press-enter!)
                    (assert.are.same ["steer"] (tasks.take! :steering))
                    (tasks.release! hid)
                    (assert.are.equal "" state.input-buf))))))
