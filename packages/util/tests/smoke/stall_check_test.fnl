;; Resource-constrained stall harness (issue #167). Opt-in: run via
;; `make stall-check` (or scripts/dev/stall-check.sh), not the default suite.
;;
;; It drives the REAL streaming transport — fen_http.so cooperative mode, the
;; real SSE parser, and a real per-event JSON decode — against a localhost
;; server pushing a multi-MB Responses-style SSE stream, exactly as a provider
;; does. FEN_DEBUG_CHUNK_DELAY_MS injects slow per-chunk cost so a desktop
;; reproduces the BB10/ARM profile.
;;
;; The metric is the TUI's metric: wall time between cooperative yields (one
;; coroutine resume). The harness prints a min/max/avg/median histogram like
;; the issue's fen.log parser and fails if any single resume exceeds the stall
;; budget. Before M1 the whole stream processed in one un-yielded resume, so
;; the worst gap was (slices * delay); with bounded draining each resume does
;; at most one ~64 KiB slice, so the gap stays near a single delay.

(local http (require :fen.util.http))
(local sse (require :fen.util.sse))
(local json (require :fen.util.json))
(local socket (require :socket))
(local process (require :fen.util.process))

(local DRAIN-BUDGET 65536) ;; FEN_CHUNK_DRAIN_BUDGET in fen_http.c

(fn env-num [name dflt]
  (let [v (os.getenv name)
        n (and v (tonumber v))]
    (if (and n (> n 0)) n dflt)))

(fn build-payload [target-bytes]
  "Synthesize a Responses-style SSE stream of ~target-bytes: many output-text
   deltas, a terminal response.completed, then [DONE]."
  (let [parts []
        ev (.. "data: {\"type\":\"response.output_text.delta\",\"delta\":\""
               (string.rep "x" 480) "\"}\n\n")]
    (var n 0)
    (while (< n target-bytes)
      (table.insert parts ev)
      (set n (+ n (length ev))))
    (table.insert parts
                  "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n")
    (table.insert parts "data: [DONE]\n\n")
    (table.concat parts)))

(fn http-response [body]
  (.. "HTTP/1.1 200 OK\r\n"
      "Content-Type: text/event-stream\r\n"
      "Content-Length: " (length body) "\r\n"
      "Connection: close\r\n\r\n"
      body))

(fn median [sorted]
  (let [n (length sorted)]
    (if (= n 0) 0
        (= (% n 2) 1) (. sorted (// (+ n 1) 2))
        (/ (+ (. sorted (// n 2)) (. sorted (+ (// n 2) 1))) 2))))

;; Drive the cooperative request against a one-shot localhost server, timing
;; each resume. Returns (response gaps) where gaps[i] is resume i's wall ms.
(fn run [body accumulate?]
  (let [server (assert (socket.bind "127.0.0.1" 0))
        (host port) (server:getsockname)
        url (.. "http://" host ":" port "/")
        resp-bytes (http-response body)
        ;; Real provider-shaped sink: SSE parse + JSON-decode every event.
        events [0]
        parser (sse.new-parser
                 (fn [ev]
                   (when (and (not= ev.data nil) (not= ev.data "")
                              (not= ev.data "[DONE]"))
                     (pcall json.decode ev.data)
                     (tset events 1 (+ (. events 1) 1)))))
        response [nil]
        gaps []
        co (coroutine.create
             (fn []
               (tset response 1
                     (http.request {:url url
                                    :method "GET"
                                    :timeout-ms 30000
                                    :connect-timeout-ms 5000
                                    :accumulate-body? accumulate?
                                    :on-chunk (fn [c] (parser.feed c))
                                    :yield (fn [] (coroutine.yield))}))
               (parser.finish)))]
    (server:settimeout 0)
    (var client nil)
    (var sent 0)
    (while (not= (coroutine.status co) :dead)
      (let [t0 (process.monotonic-ms)
            (ok? err) (coroutine.resume co)
            t1 (process.monotonic-ms)]
        (assert.is_true ok? (.. "resume failed: " (tostring err)))
        (table.insert gaps (- t1 t0)))
      (when (not client)
        (let [(c _) (server:accept)]
          (when c (set client c) (client:settimeout 0))))
      (when (and client (< sent (length resp-bytes)))
        (let [(i _err j) (client:send resp-bytes (+ sent 1))]
          (set sent (or i j sent)))))
    (server:close)
    (when client (client:close))
    (values (. response 1) gaps (. events 1))))

(describe "stall-check harness #smoke #stall"
  (fn []
    (it "keeps per-resume work bounded under injected per-chunk delay"
      (fn []
        (let [size-kb (env-num :FEN_STALL_BODY_KB 1536)
              budget (env-num :FEN_STALL_BUDGET_MS 250)
              delay (or (tonumber (os.getenv :FEN_DEBUG_CHUNK_DELAY_MS)) 0)
              body (build-payload (* size-kb 1024))
              slices (math.ceil (/ (length body) DRAIN-BUDGET))
              (r gaps events) (run body false)]
          ;; The harness only means something with injected per-chunk cost: a
          ;; delay=0 run is fast enough to satisfy `worst <= budget` even if
          ;; bounded draining were reverted, so guard against a vacuous pass.
          ;; `make stall-check` sets FEN_DEBUG_CHUNK_DELAY_MS=15.
          (assert.is_true (> delay 0)
                          "stall-check needs FEN_DEBUG_CHUNK_DELAY_MS>0 (run via `make stall-check`)")
          (assert.is_table r)
          (assert.is_nil r.error (.. "transport error: " (tostring (?. r :error))))
          (assert.are.equal 200 r.status)
          (assert.is_true (> events 0) "no SSE events were parsed")
          (let [sorted (doto (icollect [_ g (ipairs gaps)] g) (table.sort))
                n (length sorted)
                worst (. sorted n)
                med (median sorted)]
            (var sum 0)
            (each [_ g (ipairs gaps)] (set sum (+ sum g)))
            (print (string.format
                     "\nstall-check: body=%dKB slices=%d delay_ms=%d resumes=%d events=%d"
                     size-kb slices delay n events))
            (print (string.format
                     "stall-check: gap_ms min=%d max=%d avg=%.1f median=%d budget=%d injected_total_ms=%d"
                     (. sorted 1) worst (/ sum n) med budget (* slices delay)))
            ;; Prove the injected per-chunk cost was actually incurred, so the
            ;; budget check below can't pass simply because the delay knob is a
            ;; no-op. Bounded draining pays ~one delay per drained slice, spread
            ;; across resumes; the total wall time must be near slices*delay.
            (assert.is_true (>= sum (* (* slices delay) 0.5))
                            (string.format
                              "observed total %dms far below injected %dms — delay knob not applied"
                              sum (* slices delay)))
            ;; The core guarantee: no single resume blows the stall budget,
            ;; even though the total injected delay (slices*delay) far exceeds
            ;; it — i.e. the burst was spread across resumes, not run at once.
            (assert.is_true (<= worst budget)
                            (string.format
                              "worst resume %dms exceeded budget %dms (stall regression)"
                              worst budget))
            ;; With a real delay and many slices, work must visibly spread:
            ;; the worst single resume is a small fraction of the total.
            (when (and (> delay 0) (> slices 4))
              (assert.is_true (< worst (* slices delay))
                              "all chunk work landed in one resume (draining not cooperative)"))))))))
