;; Known-bug probe for #631: the web presenter handles :provider-retry in its
;; generic branch, and find-streaming-row walks back past the retry row, so a
;; retried attempt's deltas append to the failed attempt's row (network #629,
;; in web). See spec/presenters/FINDINGS.md (#631).

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local state (require :fen.extensions.web.state))
(local web (require :fen.extensions.web))
(local {: known-bug} (require :fen.testing))

(fn rows []
  (icollect [_ row (ipairs state.transcript)]
    (.. (tostring row.type) "="
        (if (= row.type :assistant-text) (tostring row.text) ""))))

(fn delta! [text]
  (events.emit {:type :assistant-text-delta :content-index 1 :delta text}))

(describe "#631 web transcript across a provider retry"
          (fn []
            (before_each (fn []
                           (test-api.reset!)
                           (set state.transcript [])
                           (set state.status-info {})
                           (web.register (test-api.make-runtime-api :web))))
            (after_each (fn [] (test-api.reset!)))
            (it "appends attempt 2's text to attempt 1's row"
                (fn []
                  (known-bug 631
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
                               (= "user= | assistant-text=Hello worHello world. | provider-retry="
                                  (table.concat (rows) " | "))))))))
