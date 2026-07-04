(local retry (require :fen.extensions.provider_shared.retry))

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

    (it "retries selected no-status transient curl codes"
      (fn []
        (assert.is_true (retry.transient? nil "unrecognized wording" 7))   ;; COULDNT_CONNECT
        (assert.is_true (retry.transient? nil "unrecognized wording" 16))  ;; HTTP2
        (assert.is_true (retry.transient? nil "unrecognized wording" 18))  ;; PARTIAL_FILE
        (assert.is_true (retry.transient? nil "unrecognized wording" 28))  ;; OPERATION_TIMEDOUT
        (assert.is_true (retry.transient? nil "unrecognized wording" 35))  ;; SSL_CONNECT_ERROR
        (assert.is_true (retry.transient? nil "unrecognized wording" 52))  ;; GOT_NOTHING
        (assert.is_true (retry.transient? nil "unrecognized wording" 55))  ;; SEND_ERROR
        (assert.is_true (retry.transient? nil "unrecognized wording" 56))  ;; RECV_ERROR
        (assert.is_true (retry.transient? nil "unrecognized wording" 92))  ;; HTTP2_STREAM
        (assert.is_false (retry.transient? nil "Server returned nothing" 6)) ;; COULDNT_RESOLVE_HOST
        (assert.is_false (retry.transient? nil "SSL certificate problem" 60))
        (assert.is_false (retry.transient? nil "Operation timed out"))))

    (it "does not let transport details make normal 4xx responses retryable"
      (fn []
        (assert.is_false (retry.transient? 400 "Operation timed out" 28))
        (assert.is_false (retry.transient? 404 "Server returned nothing" 52))
        (assert.is_false (retry.transient? 413 "Transferred a partial file" 18))))))

(describe "core.llm.retry.mark-incomplete-stream"
  (fn []
    (it "tags a clean 2xx response as retry-eligible"
      (fn []
        (let [resp (retry.mark-incomplete-stream {:status 200 :body "ok"} true)]
          (assert.is_true resp.retry-incomplete-stream))))

    (it "leaves the response untouched when not incomplete"
      (fn []
        (let [resp (retry.mark-incomplete-stream {:status 200 :body "ok"} false)]
          (assert.is_nil resp.retry-incomplete-stream))))

    (it "does not tag non-2xx, errored, or missing responses"
      (fn []
        (assert.is_nil (. (retry.mark-incomplete-stream {:status 500} true)
                          :retry-incomplete-stream))
        (assert.is_nil (. (retry.mark-incomplete-stream {:status 200 :error "boom"} true)
                          :retry-incomplete-stream))
        (assert.is_nil (. (retry.mark-incomplete-stream {:error "transport"} true)
                          :retry-incomplete-stream))))))

(describe "core.llm.retry.with-retry incomplete stream"
  (fn []
    (it "retries a marked incomplete 2xx stream then succeeds"
      (fn []
        (var calls 0)
        (var sleeps 0)
        (let [resp (retry.with-retry
                     {:max-attempts 3
                      :base-delay-ms 0
                      :max-delay-ms 0
                      :sleep (fn [_delay _yield] (set sleeps (+ sleeps 1)))}
                     (fn [_attempt]
                       (set calls (+ calls 1))
                       (if (< calls 2)
                           (retry.mark-incomplete-stream {:status 200 :body ""} true)
                           {:status 200 :body "ok"})))]
          (assert.are.equal 2 calls)
          (assert.are.equal 1 sleeps)
          (assert.are.equal 200 resp.status)
          (assert.is_nil resp.retry-incomplete-stream))))

    (it "returns the last incomplete response after attempts are exhausted"
      (fn []
        (var calls 0)
        (let [resp (retry.with-retry
                     {:max-attempts 2
                      :base-delay-ms 0
                      :max-delay-ms 0
                      :sleep (fn [_delay _yield] nil)}
                     (fn [_attempt]
                       (set calls (+ calls 1))
                       (retry.mark-incomplete-stream {:status 200 :body ""} true)))]
          (assert.are.equal 2 calls)
          (assert.are.equal 200 resp.status)
          (assert.is_true resp.retry-incomplete-stream))))))

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
                       {:error "unrecognized wording" :curl-code 52}))]
          (assert.are.equal 2 calls)
          (assert.are.equal "unrecognized wording" resp.error)
          (assert.are.equal 52 resp.curl-code))))))
