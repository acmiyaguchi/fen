;; Regression test for #630 (spec/network/FINDINGS.md): after a provider error
;; or a cancel, the open streaming row is closed so the next turn's first delta
;; starts a fresh row rather than appending to the dead turn's row.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 10}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local events (require :fen.core.extensions.events))

(fn reset! []
  (test-api.reset!)
  (tb.clear)
  (tui-test.reset-state! {:cols 80 :rows 10 :markdown? false})
  (tui.register (test-api.make-runtime-api :tui))
  (set state.tb-initialized? true)
  (paint.ensure-state-defaults!))

(fn rows []
  (icollect [_ row (ipairs state.transcript)]
    (.. (tostring row.type) "=" (if (= row.type :assistant-text)
                                    (or (and row.text-chunks
                                             (table.concat row.text-chunks ""))
                                        row.text)
                                    ""))))

(fn open-rows []
  (accumulate [n 0 _ _ (pairs (or state.streaming-assistant-rows {}))]
    (+ n 1)))

(fn delta! [text]
  (events.emit {:type :assistant-text-delta :content-index 1 :delta text}))

(fn dead-turn-then-next! [end-event]
  "Turn 1 streams and ends with END-EVENT; turn 2 streams. Returns the open
   row count after turn 1 and the transcript after turn 2's first delta."
  (events.emit {:type :user :text "q1"})
  (events.emit {:type :llm-start})
  (delta! "Partial ans")
  (events.emit end-event)
  (let [open-after-end (open-rows)]
    (events.emit {:type :user :text "q2"})
    (events.emit {:type :llm-start})
    (delta! "Fresh answer.")
    (values open-after-end (rows))))

(describe "TUI ingest after a dead turn (#630)"
          (fn []
            (before_each reset!)
            (after_each (fn [] (test-api.reset!)))
            (it "closes the open row on a provider error so the next turn starts fresh"
                (fn []
                  (let [(open transcript) (dead-turn-then-next! {:type :error
                                                                 :error "boom"})]
                    (assert.are.equal 0 open)
                    (assert.are.equal (table.concat ["user="
                                                     "assistant-text=Partial ans"
                                                     "error="
                                                     "user="
                                                     "assistant-text=Fresh answer."]
                                                    " | ")
                                      (table.concat transcript " | ")))))
            (it "closes the open row on cancel so the next turn starts fresh"
                (fn []
                  (let [(open transcript) (dead-turn-then-next! {:type :cancelled})]
                    (assert.are.equal 0 open)
                    (assert.are.equal (table.concat ["user="
                                                     "assistant-text=Partial ans"
                                                     "cancelled="
                                                     "user="
                                                     "assistant-text=Fresh answer."]
                                                    " | ")
                                      (table.concat transcript " | ")))))))
