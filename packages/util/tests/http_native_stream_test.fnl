;; End-to-end streaming test for the native fen_http backend (loads
;; fen_http.so directly). A localhost server accepts one connection and
;; pushes a fixed HTTP response; the client runs in a coroutine whose yield
;; callback calls coroutine.yield(), exactly like core.agent.make-yield.
;;
;; Covers issue #167 transport mitigations:
;;   M2 - `accumulate_body=false` must skip growing resp.body for large
;;        streaming bodies while still keeping a bounded head for error
;;        diagnostics, and on_chunk must still observe every byte.
;;   M1 - on_chunk delivery is cooperative: a large body arrives across
;;        multiple coroutine resumes rather than one un-yielded burst.

(local fen-http (require :fen_http))
(local socket (require :socket))

(local ERROR-BODY-CAP 65536)   ;; must match FEN_ERROR_BODY_CAP in fen_http.c
(local DRAIN-BUDGET 65536)     ;; must match FEN_CHUNK_DRAIN_BUDGET in fen_http.c

(fn make-response [body]
  (.. "HTTP/1.1 200 OK\r\n"
      "Content-Type: text/plain\r\n"
      "Content-Length: " (length body) "\r\n"
      "Connection: close\r\n"
      "\r\n"
      body))

;; Drive the client coroutine to completion while servicing a one-shot
;; localhost server between resumes. The server accepts (non-blocking), then
;; pushes `resp-bytes` across iterations tracking a send cursor. Returns
;; (response chunks resumes chunk-resumes) where `chunks` is the list of
;; on_chunk strings and `chunk-resumes` is the resume index each was delivered
;; on (so a test can prove deliveries interleave with yields).
(fn run-request [extra-opts body]
  (let [server (assert (socket.bind "127.0.0.1" 0))
        (host port) (server:getsockname)
        url (.. "http://" host ":" port "/")
        resp-bytes (make-response body)
        chunks []
        chunk-resumes []
        resume-box [0]
        response [nil]
        opts {:url url
              :method "GET"
              :timeout_ms 10000
              :connect_timeout_ms 5000
              :on_chunk (fn [c]
                          (table.insert chunks c)
                          (table.insert chunk-resumes (. resume-box 1)))
              :yield (fn [] (coroutine.yield))}
        _ (each [k v (pairs extra-opts)] (tset opts k v))
        co (coroutine.create
             (fn [] (tset response 1 (fen-http.request opts))))]
    (server:settimeout 0)
    (var client nil)
    (var sent 0)
    (while (not= (coroutine.status co) :dead)
      (tset resume-box 1 (+ (. resume-box 1) 1))
      (assert.is_true (< (. resume-box 1) 1000000) "runaway resume loop")
      (let [(ok? err) (coroutine.resume co)]
        (assert.is_true ok? (.. "resume failed: " (tostring err))))
      (when (not client)
        (let [(c _) (server:accept)]
          (when c (set client c) (client:settimeout 0))))
      (when (and client (< sent (length resp-bytes)))
        ;; client:send returns (last-index | nil err last-index); track the
        ;; cursor either way so a non-blocking partial send resumes next tick.
        (let [(i _err j) (client:send resp-bytes (+ sent 1))]
          (set sent (or i j sent)))))
    (server:close)
    (when client (client:close))
    (values (. response 1) chunks (. resume-box 1) chunk-resumes)))

(fn distinct-count [xs]
  (let [seen {}]
    (var n 0)
    (each [_ v (ipairs xs)]
      (when (not (. seen v)) (tset seen v true) (set n (+ n 1))))
    n))

(fn max-len [chunks]
  (var m 0)
  (each [_ c (ipairs chunks)]
    (when (> (length c) m) (set m (length c))))
  m)

(fn total-bytes [chunks]
  (var n 0)
  (each [_ c (ipairs chunks)] (set n (+ n (length c))))
  n)

(describe "fen_http streaming body accumulation"
  (fn []
    (it "accumulates the full body by default"
      (fn []
        (let [body (string.rep "x" 4096)
              (r chunks) (run-request {} body)]
          (assert.is_table r)
          (assert.is_nil r.error (.. "unexpected error: " (tostring (?. r :error))))
          (assert.are.equal 200 r.status)
          (assert.are.equal (length body) (length r.body))
          (assert.are.equal (length body) (total-bytes chunks)))))

    (it "skips accumulation past the cap when accumulate_body=false"
      (fn []
        ;; Body well past the cap: resp.body is held to a bounded head while
        ;; on_chunk still observes every byte (the streamed result is built
        ;; from chunks, not resp.body).
        (let [body (string.rep "y" (* 3 ERROR-BODY-CAP))
              (r chunks) (run-request {:accumulate_body false} body)]
          (assert.is_table r)
          (assert.is_nil r.error (.. "unexpected error: " (tostring (?. r :error))))
          (assert.are.equal 200 r.status)
          (assert.are.equal ERROR-BODY-CAP (length r.body)
                            "resp.body must be capped at FEN_ERROR_BODY_CAP")
          (assert.are.equal (length body) (total-bytes chunks)
                            "on_chunk must still see every byte"))))

    (it "keeps a sub-cap body intact even with accumulate_body=false"
      (fn []
        (let [body (string.rep "z" 1024)
              (r chunks) (run-request {:accumulate_body false} body)]
          (assert.is_table r)
          (assert.is_nil r.error)
          (assert.are.equal (length body) (length r.body))
          (assert.are.equal (length body) (total-bytes chunks)))))))

(describe "fen_http cooperative chunk draining"
  (fn []
    (it "delivers a large body across multiple resumes, bounded per slice"
      (fn []
        ;; A body several drain budgets long must arrive in on_chunk slices
        ;; spread across more than one resume (a yield between slices), with no
        ;; single slice exceeding the budget — that's what keeps the TUI
        ;; repainting instead of stalling on one big burst.
        (let [body (string.rep "q" (* 5 DRAIN-BUDGET))
              (r chunks _resumes chunk-resumes)
              (run-request {:accumulate_body false} body)]
          (assert.is_table r)
          (assert.is_nil r.error (.. "unexpected error: " (tostring (?. r :error))))
          (assert.are.equal (length body) (total-bytes chunks)
                            "every byte must reach on_chunk")
          (assert.is_true (<= (max-len chunks) DRAIN-BUDGET)
                          (.. "a slice exceeded the drain budget: " (max-len chunks)))
          (assert.is_true (> (distinct-count chunk-resumes) 1)
                          "chunk delivery must interleave with yields (>1 resume)"))))))
