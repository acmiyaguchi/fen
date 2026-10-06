(local bench (require :fen.testing.tui_latency))

(fn delta [at marker text] {: at : marker : text})
(fn sample [result i field] (. result.samples i field))

(describe "production-loop input and stream visibility latency"
          (fn []
            (it "presents typed text only after a blocked tick returns and catches queued keys"
                (fn []
                  (let [opts {:keys [{:at 17 :text "a"} {:at 40 :text "b"}]
                              :finish-at 300
                              :frames? true}
                        baseline (bench.run opts)]
                    (assert.are.equal 0 baseline.input.max)
                    (set opts.stall-tick 1)
                    (set opts.tick-delay-ms 100)
                    (let [blocked (bench.run opts)]
                      (assert.are.equal 100 (sample blocked 1 :latency))
                      (assert.are.equal 77 (sample blocked 2 :latency))
                      (assert.are.equal 117 (sample blocked 1 :visible))
                      (assert.are.equal 117 (sample blocked 2 :delivered))
                      (assert.are.equal 0 (length blocked.missing))
                      (assert.are.equal "ab" blocked.draft)))))
            (it "includes presentation delay rather than stopping at input-buffer mutation"
                (fn []
                  (let [r (bench.run {:keys [{:at 17 :text "a"}]
                                      :present-delay-ms 40
                                      :finish-at 300})]
                    ;; Initial paint also blocks a key that arrives while it is painting.
                    (assert.are.equal 63 r.input.max)
                    (assert.are.equal 80 (sample r 1 :visible)))))
            (it "waits for the active poll before ingesting provider deltas, not just paint CPU"
                (fn []
                  (let [r (bench.run {:deltas [(delta 1 "FIRST" "FIRST\n")]
                                      :end-at 70
                                      :finish-at 180})]
                    (assert.are.equal 29 r.delta.max)
                    (assert.are.equal 30 (sample r 1 :delivered))
                    (assert.are.equal 30 (. r.polls 1))
                    (assert.are.equal 0 (length r.missing)))))
            (it "leaves tiny deltas invisible until 128 pending bytes or final flush"
                (fn []
                  (let [r (bench.run {:deltas [(delta 1 "FIRST" "FIRST\n")
                                               (delta 31 "SECOND" "SECOND\n")
                                               ;; 7 + 121 pending bytes crosses the production threshold.
                                               (delta 91 "THIRD"
                                                      (.. "THIRD"
                                                          (string.rep "." 115)
                                                          "\n"))
                                               (delta 121 "TAIL" "TAIL\n")]
                                      :end-at 181
                                      :finish-at 270
                                      :frames? true})]
                    (assert.are.equal 30 (sample r 1 :visible))
                    (assert.are.equal 120 (sample r 2 :visible))
                    (assert.are.equal 120 (sample r 3 :visible))
                    (assert.are.equal 210 (sample r 4 :visible))
                    (assert.are.equal 89 (sample r 2 :latency))
                    (assert.are.equal 0 (length r.missing))
                    ;; Assert an actual intermediate presented frame excludes pending text.
                    (assert.is_nil (string.find (. r.frames 2 :text) "SECOND" 1
                                                true)))))
            (it "keeps typing responsive but cached pending text waits for stream flush"
                (fn []
                  (let [r (bench.run {:keys [{:at 77 :text "a"}
                                             {:at 100 :text "b"}]
                                      :deltas [(delta 1 "FIRST" "FIRST\n")
                                               (delta 31 "SECOND" "SECOND\n")]
                                      :end-at 181
                                      :finish-at 270})]
                    (assert.are.equal 190 (sample r 2 :visible))
                    (assert.are.equal 159 (sample r 2 :latency))
                    (assert.are.equal 0 r.input.max)
                    (assert.are.equal "ab" r.draft)
                    (assert.are.equal 0 (length r.missing)))))
            (it "records all deltas from one burst at a shared presented boundary"
                (fn []
                  (let [r (bench.run {:deltas [(delta 1 "ONE" "ONE\n")
                                               (delta 2 "TWO" "TWO\n")
                                               (delta 3 "THREE" "THREE\n")]
                                      :end-at 70
                                      :finish-at 180})]
                    (assert.are.equal 3 r.delta.n)
                    (assert.are.equal 30 (sample r 1 :visible))
                    (assert.are.equal 30 (sample r 2 :visible))
                    (assert.are.equal 30 (sample r 3 :visible))
                    (assert.are.equal 29 r.delta.max))))))
