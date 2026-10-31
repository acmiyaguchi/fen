;; Known-bug probe for #630: after a provider error or a cancel the agent
;; emits no assistant-stream-end, and neither the :error nor the :cancelled
;; handler closes the open streaming row, so the next turn's first delta
;; appends to the dead turn's row.
;; See spec/network/FINDINGS.md (#630).

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 10}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local events (require :fen.core.extensions.events))
(local {: known-bug} (require :fen.testing))

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

(fn joined? [open-after-end transcript end-type]
  (and (= 1 open-after-end)
       (= (table.concat ["user="
                         "assistant-text=Partial ansFresh answer."
                         (.. end-type "=")
                         "user="] " | ")
          (table.concat transcript " | "))))

(describe "#630 TUI ingest after a dead turn"
          (fn []
            (before_each reset!)
            (after_each (fn [] (test-api.reset!)))
            (it "reuses the open row after a provider error"
                (fn []
                  (known-bug 630
                             (fn []
                               (let [(open transcript) (dead-turn-then-next! {:type :error
                                                                              :error "boom"})]
                                 (joined? open transcript :error))))))
            (it "reuses the open row after a cancel"
                (fn []
                  (known-bug 630
                             (fn []
                               (let [(open transcript) (dead-turn-then-next! {:type :cancelled})]
                                 (joined? open transcript :cancelled))))))))
