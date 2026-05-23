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
                (.. "fen_http leaked a C-yield error: " r.error)))))))))
