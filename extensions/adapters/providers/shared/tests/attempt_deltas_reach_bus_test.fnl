;; Regression test for #629 (spec/network/FINDINGS.md): the streaming skeleton
;; gives every retry attempt a fresh parser and builds the assistant message
;; from the last attempt only. Each attempt's deltas reach on-event as they
;; arrive, separated by :provider-retry, while the returned message holds only
;; the successful attempt's text.

(local testing (require :fen.testing))
(local types (require :fen.core.types))
(local json (require :fen.util.json))

(fn new-state [model]
  {: model :content [] :usage nil :stop-reason :stop :saw-terminal? false})

(fn process-event [state ev emit]
  ;; A minimal provider reducer: {"t":"delta","d":...} streams text into one
  ;; block; {"t":"done"} is the terminal event.
  (if (= ev.t "delta")
      (do
        (when (= (length state.content) 0)
          (table.insert state.content (types.text-block "")))
        (let [block (. state.content 1)]
          (set block.text (.. block.text ev.d)))
        (emit {:type :text-delta :content-index 1 :delta ev.d}))
      (= ev.t "done")
      (set state.saw-terminal? true)))

(fn frame [obj]
  (.. "data: " (json.encode obj) "\n\n"))

(fn run-two-attempts []
  "Attempt 1 streams 'Hello wor' and ends without its terminal event (a
   transient failure); attempt 2 streams 'Hello world.' and completes."
  (let [calls {:n 0}
        seen []]
    (testing.stub-http! (fn [opts]
                          (set calls.n (+ calls.n 1))
                          (if (= calls.n 1)
                              (opts.on-chunk (frame {:t "delta" :d "Hello wor"}))
                              (do
                                (opts.on-chunk (frame {:t "delta"
                                                       :d "Hello world."}))
                                (opts.on-chunk (frame {:t "done"}))))
                          {:status 200 :body "" :headers {}}))
    (tset package.loaded :fen.extensions.provider_shared.streaming nil)
    (let [streaming (require :fen.extensions.provider_shared.streaming)
          on-event (fn [ev] (table.insert seen ev))
          asst (streaming.complete-streaming {:provider :probe
                                              :model "m"
                                              :context {:messages []}
                                              :options {:retry-max-attempts 2
                                                        :retry-base-delay-ms 0
                                                        :retry-max-delay-ms 0}
                                              : on-event
                                              :make-stream-pipeline (fn [model
                                                                         emit]
                                                                      (streaming.make-stream-pipeline {: model
                                                                                                       : new-state
                                                                                                       : process-event
                                                                                                       :on-event emit}))
                                              :build-request-opts (fn [_model
                                                                       _context
                                                                       _options
                                                                       on-chunk]
                                                                    {:method :POST
                                                                     :url "http://probe.invalid"
                                                                     :body "{}"
                                                                     : on-chunk})
                                              :finalize-stream (fn [state
                                                                    parser
                                                                    parser-error
                                                                    model
                                                                    resp
                                                                    emit]
                                                                 (streaming.finalize-stream {:api :probe
                                                                                             :provider :probe
                                                                                             : model
                                                                                             : state
                                                                                             : parser
                                                                                             : parser-error
                                                                                             : resp
                                                                                             :on-event emit
                                                                                             :finalize-state (fn [st
                                                                                                                  ev-fn]
                                                                                                               (streaming.finalize-stream-state {:api :probe
                                                                                                                                                 :provider :probe
                                                                                                                                                 :state st
                                                                                                                                                 :emit ev-fn}))}))})]
      (testing.restore-http!)
      (tset package.loaded :fen.extensions.provider_shared.streaming nil)
      (values asst seen calls.n))))

(describe "streaming skeleton across a retry (#629)"
          (fn []
            (after_each (fn []
                          (testing.restore-http!)
                          (tset package.loaded
                                :fen.extensions.provider_shared.streaming nil)))
            (it "streams deltas with :provider-retry boundary while message holds last attempt only"
                (fn []
                  (let [(asst seen attempts) (run-two-attempts)
                        kinds (icollect [_ ev (ipairs seen)]
                                (if (= ev.type :text-delta)
                                    (.. "delta:" ev.content-index ":" ev.delta)
                                    (when (not= ev.type :start)
                                      (tostring ev.type))))]
                    (assert.are.equal 2 attempts)
                    (assert.are.equal "Hello world."
                                      (types.assistant-text asst))
                    (assert.are.equal (table.concat ["delta:1:Hello wor"
                                                     :provider-retry
                                                     "delta:1:Hello world."
                                                     :done]
                                                    " ")
                                      (table.concat kinds " ")))))))
