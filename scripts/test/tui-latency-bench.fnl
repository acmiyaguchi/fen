;; Run from repository root with make bench-tui-latency.
(local fennel (require :fennel))
(let [paths ["./scripts/?.fnl"]
      p (assert (io.popen "find packages -path '*/src' -type d | sort"))]
  (each [dir (p:lines)]
    (table.insert paths (.. dir "/?.fnl"))
    (table.insert paths (.. dir "/?/init.fnl")))
  (p:close)
  (set fennel.path (.. (table.concat paths ";") ";" fennel.path))
  (fennel.install))

((. (require :fen.util.flat_extensions) :install!) {:roots ["extensions"]
                                                    :fennel fennel
                                                    :position 2})

;; The replay replaces the clock; no native clock library is needed.
(local socket (require :socket))
(tset package.loaded :fen.util.clock.backend
      {:monotonic-ms #(math.floor (* 1000 (socket.gettime)))
       :sleep-ms #(socket.sleep (/ $1 1000))})

(local bench (require :fen.testing.tui_latency))

(fn keys []
  (let [out []]
    (for [i 1 24]
      (table.insert out {:at (+ 17 (* (- i 1) 43))
                         :text (string.char (+ 96 i))}))
    out))

(fn deltas [interval count size]
  (let [out []]
    (for [i 1 count]
      (let [marker (string.format "D%03d" i)]
        (table.insert out
                      {:at (+ 11 (* (- i 1) interval))
                       : marker
                       :text (.. marker (string.rep "." (- size 5)) "\n")})))
    out))

(local scenarios [{:name "idle typing" :keys (keys) :busy? false}
                  {:name "active typing" :keys (keys)}
                  {:name "small slow deltas"
                   :deltas (deltas 80 18 8)
                   :end-at 1600}
                  {:name "burst deltas" :deltas (deltas 1 24 8) :end-at 100}
                  {:name "typing while streaming"
                   :keys (keys)
                   :deltas (deltas 55 24 8)
                   :end-at 1600}
                  {:name "long transcript + typing/stream"
                   :keys (keys)
                   :deltas (deltas 55 24 8)
                   :end-at 1600
                   :history 1000
                   :thinking? true}])

(fn report [scenario mode result]
  (print (string.format "%s [%s] history=%d presents=%d ticks=%d CPU=%.2fms run-wall=%.2fms"
                        scenario.name mode (or scenario.history 0)
                        result.presents result.ticks result.cpu-ms
                        result.wall-ms))
  (each [_ kind (ipairs [:input :delta])]
    (let [s (. result kind)]
      (when (> s.n 0)
        (print (string.format "  %-5s n=%d median=%.3f p95=%.3f max=%.3f ms"
                              kind s.n s.median s.p95 s.max)))))
  (let [s result.frame-cpu]
    (print (string.format "  frame CPU n=%d median=%.3f p95=%.3f max=%.3f ms"
                          s.n s.median s.p95 s.max)))
  (assert (= 0 (length result.missing))
          "scheduled text never appeared in a presented frame")
  (assert (= (+ (length (or scenario.keys [])) (length (or scenario.deltas [])))
             (length result.samples))
          "replay quit before all arrivals"))

(print "TUI latency: production run/input/bus/ingest/paint; 100x32, Markdown, cold first frame.")
(print "logical = scheduled fake clock (no host execution cost); wall = real timed replay to present return.")
(print "CPU/run-wall include capture overhead; native terminal/transport are excluded. No latency budgets enforced.")
(each [_ scenario (ipairs scenarios)]
  (set scenario.wall? false)
  (report scenario "logical" (bench.run scenario))
  (when (not= (. arg 1) "--logical-only")
    (set scenario.wall? true)
    (report scenario "wall" (bench.run scenario))))
