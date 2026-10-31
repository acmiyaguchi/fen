;; Regression test for #631 (spec/presenters/FINDINGS.md): a provider retry
;; drops the failed attempt's text from the open web row, so the transcript
;; shows only what history holds; an :error or :cancelled closes the open row so
;; the next turn's text cannot join a dead turn's row.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local state (require :fen.extensions.web.state))
(local web (require :fen.extensions.web))

(fn rows []
  (icollect [_ row (ipairs state.transcript)]
    (.. (tostring row.type) "="
        (if (= row.type :assistant-text) (tostring row.text) ""))))

(fn delta! [text]
  (events.emit {:type :assistant-text-delta :content-index 1 :delta text}))

(describe "web transcript across a provider retry (#631)"
          (fn []
            ;; Register once: reset! leaves web's bus handlers installed, so a
            ;; per-test register would stack them and repeat every row.
            (setup (fn []
                     (test-api.reset!)
                     (web.register (test-api.make-runtime-api :web))))
            (before_each (fn []
                           (set state.transcript [])
                           (set state.status-info {})))
            (teardown (fn [] (test-api.reset!)))
            (it "shows only the attempt that succeeded"
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
                  (events.emit {:type :assistant-stream-end :final? true})
                  (assert.are.equal "user= | assistant-text=Hello world. | provider-retry="
                                    (table.concat (rows) " | "))))
            (it "does not join the next turn's text onto a cancelled turn's row"
                (fn []
                  (events.emit {:type :user :text "q"})
                  (delta! "Partial ans")
                  (events.emit {:type :cancelled})
                  (delta! "Fresh")
                  (events.emit {:type :assistant-stream-end :final? true})
                  (assert.are.equal "user= | assistant-text=Partial ans | cancelled= | assistant-text=Fresh"
                                    (table.concat (rows) " | "))))
            (it "does not join the next turn's text onto an errored turn's row"
                (fn []
                  (events.emit {:type :user :text "q"})
                  (delta! "Partial ans")
                  (events.emit {:type :error :error "boom"})
                  (delta! "Fresh")
                  (assert.are.equal "user= | assistant-text=Partial ans | error= | assistant-text=Fresh"
                                    (table.concat (rows) " | "))))))
