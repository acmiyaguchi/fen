;; Clock seam tests (#472): the public module dispatches through an injectable
;; backend, and the default backend wraps the fen_process native clock.

(local testing (require :fen.testing))

(describe "util.clock backend seam"
  (fn []
    (after_each
      (fn []
        (testing.restore-clock!)))

    (it "dispatches monotonic-ms and sleep-ms through the injected backend"
      (fn []
        (var sleeps [])
        (testing.stub-clock!
          {:monotonic-ms (fn [] 4242)
           :sleep-ms (fn [ms] (table.insert sleeps ms) true)})
        (let [clock (testing.reload-module :fen.util.clock)]
          (assert.are.equal 4242 (clock.monotonic-ms))
          (clock.sleep-ms 17)
          (clock.sleep-ms 3)
          (assert.are.same [17 3] sleeps))))

    (it "uses the fen_process native backend by default"
      (fn []
        ;; No stub: exercise the real default backend end to end.
        (testing.restore-clock!)
        (let [clock (testing.reload-module :fen.util.clock)
              t0 (clock.monotonic-ms)]
          (assert.is_true (>= t0 0))
          (clock.sleep-ms 5)
          (let [t1 (clock.monotonic-ms)]
            (assert.is_true (>= t1 t0))))))

    (it "requiring the clock never pulls in the subprocess module"
      (fn []
        ;; The whole point of the split: an embedded/headless turn that only
        ;; needs the clock must not force fen.util.process (and thus fen_process
        ;; spawn/pipe) to load.
        (tset package.loaded :fen.util.process nil)
        (testing.restore-clock!)
        (testing.reload-module :fen.util.clock)
        (assert.is_nil (. package.loaded :fen.util.process))))))
