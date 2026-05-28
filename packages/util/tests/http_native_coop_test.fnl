;; End-to-end cooperative-yield test for the native fen_http backend.
;; Loads fen_http.so directly (not the test stub) and drives it from a
;; Lua coroutine whose yield callback calls coroutine.yield(). The
;; agent loop relies on this exact pattern (see core.agent.make-yield),
;; so a regression here breaks every interactive HTTP request.
;;
;; Strategy: bind a localhost TCP socket but never accept/respond. curl
;; then sits in connect/read with curl_multi_perform returning still-
;; running until a short request timeout fires; perform_coop fires the
;; yield callback between iterations. With the bug, the very first
;; yield panics ("attempt to yield across a C-call boundary") and the
;; coroutine completes in one resume. Once fixed, the coroutine yields
;; many times, the test driver re-resumes it, and the request finishes
;; with a timeout error rather than a callback error.

(local fen-http (require :fen_http))
(local socket (require :socket))

(fn drive [co]
  "Run a coroutine to completion as a cooperative resumer would. Returns
   the number of resumes (>= 1). Asserts the coroutine never errors."
  (var resumes 0)
  (while (not= (coroutine.status co) :dead)
    (set resumes (+ resumes 1))
    (assert.is_true (< resumes 1000000) "runaway resume loop")
    (let [(ok? err) (coroutine.resume co)]
      (assert.is_true ok? (.. "resume failed: " (tostring err)))))
  resumes)

(describe "fen_http cooperative yield"
  (fn []
    (it "yields through the C boundary without panicking"
      (fn []
        (let [server (assert (socket.bind "127.0.0.1" 0))
              (host port) (server:getsockname)
              url (.. "http://" host ":" port "/")
              yield-count [0]
              response [nil]
              co (coroutine.create
                   (fn []
                     (let [r (fen-http.request
                              {:url url
                               :method "GET"
                               :timeout_ms 500
                               :connect_timeout_ms 500
                               :yield (fn []
                                        (tset yield-count 1
                                              (+ (. yield-count 1) 1))
                                        (coroutine.yield))})]
                       (tset response 1 r))))
              resumes (drive co)]
          (server:close)
          (assert.is_true (> resumes 1)
                          (.. "expected > 1 resume (cooperative yield); got "
                              (tostring resumes)))
          (assert.is_true (> (. yield-count 1) 0)
                          "yield callback never ran")
          (let [r (. response 1)]
            (assert.is_table r)
            (when r.error
              (assert.is_number r.curl_code)
              (assert.is_nil
                (string.find r.error "yield across" 1 true)
                (.. "fen_http leaked a C-yield error: " r.error)))))))

    (it "propagates a raised cancel marker through the C boundary with cleanup"
      (fn []
        (let [server (assert (socket.bind "127.0.0.1" 0))
              (host port) (server:getsockname)
              url (.. "http://" host ":" port "/")
              marker {:type :cancel-marker}
              calls [0]
              co (coroutine.create
                   (fn []
                     (fen-http.request
                       {:url url
                        :method "GET"
                        :timeout_ms 5000
                        :connect_timeout_ms 5000
                        :yield (fn []
                                 (tset calls 1 (+ (. calls 1) 1))
                                 (coroutine.yield)
                                 (when (>= (. calls 1) 2)
                                   (error marker)))})))]
          ;; The agent's make-yield raises a unique table on cancel. With the
          ;; pre-fix lua_callk the raise longjmped past cleanup (leaking the
          ;; curl easy/multi handles); the protected lua_pcallk path frees
          ;; them and re-raises the same object. The freed handles aren't
          ;; observable from Lua, but the exact error identity propagating
          ;; (no swallow into {error=...}, no C-boundary panic) is the guard.
          (var ok? true)
          (var err nil)
          (while (and ok? (not= (coroutine.status co) :dead))
            (let [(o e) (coroutine.resume co)]
              (set ok? o)
              (when (not o) (set err e))))
          (server:close)
          (assert.is_false ok? "the raised marker must propagate, not be swallowed")
          (assert.are.equal marker err
                            "the exact error object identity must survive the C boundary"))))

    (it "aborts a silent stream within the idle window, not the full timeout"
      (fn []
        ;; Bind but never respond: curl connects (the kernel completes the
        ;; handshake into the backlog) and waits for bytes that never arrive.
        ;; With a large overall ceiling and a short idle window the low-speed
        ;; watchdog must trip near idle_timeout_ms, proving it applies on the
        ;; cooperative curl_multi path. (A partial-then-silent stream takes
        ;; longer because curl averages speed over a multi-second window;
        ;; pure silence is the prompt, common stall.)
        (let [server (assert (socket.bind "127.0.0.1" 0))
              (host port) (server:getsockname)
              url (.. "http://" host ":" port "/")
              response [nil]
              start (socket.gettime)
              co (coroutine.create
                   (fn []
                     (tset response 1
                           (fen-http.request
                             {:url url
                              :method "GET"
                              :timeout_ms 20000
                              :connect_timeout_ms 4000
                              :idle_timeout_ms 1000
                              :yield (fn [] (coroutine.yield))}))))
              resumes (drive co)]
          (server:close)
          (let [elapsed (- (socket.gettime) start)
                r (. response 1)]
            (assert.is_table r)
            (assert.is_string r.error)
            ;; CURLE_OPERATION_TIMEDOUT — what a low-speed (idle) abort raises.
            (assert.are.equal 28 r.curl_code)
            (assert.is_true (< elapsed 10)
                            (.. "idle abort should fire near idle_timeout_ms, not timeout_ms; took "
                                (tostring elapsed) "s"))))))))
