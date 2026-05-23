(local process (require :fen.util.process))

(fn read-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

(describe "util.process.run-captured"
  (fn []
    (it "captures output, exit code, and duration for a fast command"
      (fn []
        (let [r (process.run-captured {:cmd "echo hello"})]
          (assert.are.equal 0 r.exit-code)
          (assert.is_nil r.signal)
          (assert.is_false r.timed-out?)
          (assert.is_truthy (string.find r.output "hello" 1 true))
          (assert.is_true (>= r.duration-ms 0)))))

    (it "keeps a bounded tail and spills complete output when requested"
      (fn []
        (let [r (process.run-captured {:cmd "seq 1 2000"
                                       :max-lines 5
                                       :max-bytes 200
                                       :spill? true})]
          (assert.are.equal 0 r.exit-code)
          (assert.is_true r.truncated?)
          (assert.is_truthy r.full-output-path)
          (assert.is_truthy (string.find r.output "2000" 1 true))
          (assert.is_falsy (string.find r.output "^1\n"))
          (let [full (read-file r.full-output-path)]
            (assert.is_truthy full)
            (assert.is_truthy (string.find full "1\n2\n3" 1 true))
            (assert.is_truthy (string.find full "2000" 1 true))))))

    (it "times out silent commands promptly"
      (fn []
        (let [start (process.monotonic-ms)
              r (process.run-captured {:cmd "sleep 5"
                                       :timeout-seconds 0.2
                                       :kill-grace-ms 100})
              elapsed (- (process.monotonic-ms) start)]
          (assert.is_true r.timed-out?)
          (assert.is_true (< elapsed 1200)
                          (.. "timeout took too long: " (tostring elapsed) "ms")))))

    (it "escalates TERM-ignoring commands to KILL promptly"
      (fn []
        (let [start (process.monotonic-ms)
              r (process.run-captured {:cmd "trap '' TERM; sleep 5"
                                       :timeout-seconds 0.2
                                       :kill-grace-ms 100})
              elapsed (- (process.monotonic-ms) start)]
          (assert.is_true r.timed-out?)
          (assert.is_true (< elapsed 1500)
                          (.. "TERM-ignoring timeout took too long: "
                              (tostring elapsed) "ms")))))

    (it "does not wait forever for background descendants holding stdout open"
      (fn []
        (let [start (process.monotonic-ms)
              r (process.run-captured {:cmd "sleep 2 & echo parent-done"
                                       :post-exit-drain-ms 100})
              elapsed (- (process.monotonic-ms) start)]
          (assert.are.equal 0 r.exit-code)
          (assert.is_truthy (string.find r.output "parent-done" 1 true))
          (assert.is_true (< elapsed 1000)
                          (.. "background pipe test took too long: "
                              (tostring elapsed) "ms")))))

    (it "reports signal-killed children distinctly from exit codes"
      (fn []
        (let [r (process.run-captured {:cmd "kill -KILL $$"})]
          (assert.is_nil r.exit-code)
          (assert.are.equal 9 r.signal))))

    (it "yields during large output bursts even before the pipe goes idle"
      (fn []
        (var yields 0)
        (let [r (process.run-captured {:cmd "yes | head -c 200000"
                                       :max-bytes 1000
                                       :max-lines 10}
                                      (fn [] (set yields (+ yields 1))))]
          (assert.are.equal 0 r.exit-code)
          (assert.is_true (> (?. r :stats :total-bytes) 100000))
          (assert.is_true (> yields 0)))))

    (it "kills a silent child before unwinding cooperative cancellation"
      (fn []
        (let [start (process.monotonic-ms)
              (ok? err) (pcall process.run-captured
                                {:cmd "sleep 5"}
                                (fn [] (error :cancel-process-test)))
              elapsed (- (process.monotonic-ms) start)]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err)
                                          "cancel%-process%-test"))
          (assert.is_true (< elapsed 1000)
                          (.. "cancel cleanup took too long: "
                              (tostring elapsed) "ms")))))))
