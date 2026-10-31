;; Regression test for #629 (spec/network/FINDINGS.md): a provider retry drops
;; the failed attempt's text from the open streaming row, so the transcript
;; shows only what history holds.

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

(fn assistant-texts []
  (icollect [_ row (ipairs state.transcript)]
    (when (= row.type :assistant-text)
      (or (and row.text-chunks (table.concat row.text-chunks "")) row.text))))

(fn delta! [text]
  (events.emit {:type :assistant-text-delta :content-index 1 :delta text}))

(describe "TUI ingest across a provider retry (#629)"
          (fn []
            (before_each reset!)
            (after_each (fn [] (test-api.reset!)))
            (it "drops the failed attempt's text on retry and shows only the successful reply"
                (fn []
                  (events.emit {:type :user :text "q"})
                  (events.emit {:type :llm-start})
                  (delta! "Hello wor")
                  (events.emit {:type :provider-retry
                                :attempt 2
                                :max-attempts 4
                                :delay-ms 0
                                :reason "HTTP 500"})
                  (delta! "Hello world.")
                  (events.emit {:type :llm-end})
                  (events.emit {:type :assistant-stream-end
                                :final? true})
                  (let [texts (assistant-texts)]
                    (assert.are.equal 1 (length texts))
                    (assert.are.equal "Hello world." (. texts 1)))))))
