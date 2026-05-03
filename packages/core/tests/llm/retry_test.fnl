(local retry (require :fen.core.llm.retry))

(describe "core.llm.retry.transient?"
  (fn []
    (it "retries only conservative transient statuses"
      (fn []
        (assert.is_true (retry.transient? 429 nil))
        (assert.is_true (retry.transient? 500 nil))
        (assert.is_true (retry.transient? 502 nil))
        (assert.is_true (retry.transient? 503 nil))
        (assert.is_true (retry.transient? 504 nil))
        (assert.is_false (retry.transient? 400 nil))
        (assert.is_false (retry.transient? 401 nil))
        (assert.is_false (retry.transient? 404 nil))
        (assert.is_false (retry.transient? 413 nil))))

    (it "retries selected transient transport errors"
      (fn []
        (assert.is_true (retry.transient? nil "Operation timed out"))
        (assert.is_true (retry.transient? nil "connection reset by peer"))
        (assert.is_true (retry.transient? nil "connection refused"))
        (assert.is_false (retry.transient? nil "could not resolve host"))))))

(describe "core.llm.retry.parse-retry-after"
  (fn []
    (it "parses retry-after-ms and retry-after seconds"
      (fn []
        (assert.are.equal 250 (retry.parse-retry-after {:retry-after-ms "250"}))
        (assert.are.equal 2000 (retry.parse-retry-after {:Retry-After "2"}))))

    (it "parses HTTP-date values"
      (fn []
        (assert.are.equal 0 (retry.parse-retry-after
                              {:Retry-After "Wed, 21 Oct 2015 07:28:00 GMT"}))))

    (it "falls back to nil for unparseable values"
      (fn []
        (assert.is_nil (retry.parse-retry-after {:Retry-After "not a date"}))))))

(describe "core.llm.retry.backoff-delay"
  (fn []
    (it "returns jitter inside the exponential cap"
      (fn []
        (for [attempt 1 4]
          (let [delay (retry.backoff-delay attempt 100 10000)
                cap (* 100 (^ 2 (- attempt 1)))]
            (assert.is_true (>= delay 0))
            (assert.is_true (<= delay cap))))))

    (it "allows zero-delay tests"
      (fn []
        (assert.are.equal 0 (retry.backoff-delay 1 0 0))))))

(describe "core.llm.retry.with-retry"
  (fn []
    (it "retries transient failures then returns success"
      (fn []
        (var calls 0)
        (var sleeps 0)
        (let [events []
              resp (retry.with-retry
                     {:max-attempts 3
                      :base-delay-ms 0
                      :max-delay-ms 0
                      :sleep (fn [_delay _yield] (set sleeps (+ sleeps 1)))
                      :on-retry #(table.insert events $1)}
                     (fn [_attempt]
                       (set calls (+ calls 1))
                       (if (< calls 3)
                           {:status 503 :body "busy"}
                           {:status 200 :body "ok"})))]
          (assert.are.equal 3 calls)
          (assert.are.equal 2 sleeps)
          (assert.are.equal 2 (length events))
          (assert.are.equal 200 resp.status))))

    (it "does not retry terminal failures"
      (fn []
        (var calls 0)
        (let [resp (retry.with-retry
                     {:max-attempts 3
                      :sleep (fn [_delay _yield] (error "should not sleep"))}
                     (fn [_attempt]
                       (set calls (+ calls 1))
                       {:status 401 :body "auth"}))]
          (assert.are.equal 1 calls)
          (assert.are.equal 401 resp.status))))

    (it "returns the last transient failure after attempts are exhausted"
      (fn []
        (var calls 0)
        (let [resp (retry.with-retry
                     {:max-attempts 2
                      :base-delay-ms 0
                      :max-delay-ms 0
                      :sleep (fn [_delay _yield] nil)}
                     (fn [_attempt]
                       (set calls (+ calls 1))
                       {:error "timeout"}))]
          (assert.are.equal 2 calls)
          (assert.are.equal "timeout" resp.error))))))
