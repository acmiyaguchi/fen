(local process (require :fen.util.process))

(fn read-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

(fn have-cmd? [name]
  (let [ok? (os.execute (.. "command -v " name " >/dev/null 2>&1"))]
    ;; Lua 5.4 os.execute returns true/nil, not the shell status integer.
    (or (= ok? true) (= ok? 0))))

(fn await-job [job]
  (var done? false)
  (var result nil)
  (while (not done?)
    (let [(tick-done? tick-result) (job:resume)]
      (set done? tick-done?)
      (set result tick-result))
    (when (not done?) (process.sleep-ms 5)))
  result)

(describe "util.process.start-captured"
  (fn []
    (it "returns promptly when a silent child has made no progress"
      (fn []
        (let [job (process.start-captured {:cmd "sleep 1"})
              start (process.monotonic-ms)
              (done? result) (job:resume)
              elapsed (- (process.monotonic-ms) start)]
          (assert.is_false done?)
          (assert.is_nil result)
          (assert.is_true (< elapsed 100)
                          (.. "resume blocked for " (tostring elapsed) "ms"))
          (job:abort)
          (await-job job))))

    (it "captures output over resumable ticks"
      (fn []
        (let [job (process.start-captured {:cmd "printf hello"})
              r (await-job job)]
          (assert.are.equal 0 r.exit-code)
          (assert.are.equal "hello" r.output)
          (assert.is_false r.cancelled?))))

    (it "aborts idempotently and reports cancellation"
      (fn []
        (let [job (process.start-captured {:cmd "sleep 5"})]
          (job:abort)
          (job:abort)
          (let [r (await-job job)
                (done-again? r-again) (job:resume)]
            (assert.is_true r.cancelled?)
            (assert.are.equal 9 r.signal)
            (assert.is_true done-again?)
            (assert.are.equal r r-again)
            ;; Aborting a completed handle is harmless.
            (job:abort)))))

    (it "advances timeout TERM and KILL transitions across ticks"
      (fn []
        (let [job (process.start-captured {:cmd "trap '' TERM; sleep 5"
                                           :timeout-seconds 0.2
                                           :kill-grace-ms 30})]
          ;; Let the shell install its TERM trap and the timeout expire.
          (process.sleep-ms 220)
          (let [start (process.monotonic-ms)
              (first-done?) (job:resume)
              first-elapsed (- (process.monotonic-ms) start)]
          ;; The first expired-timeout tick sends TERM but must not wait through
          ;; the grace period before returning.
          (assert.is_false first-done?)
          (assert.is_true (< first-elapsed 100))
          (process.sleep-ms 40)
          (let [r (await-job job)]
            (assert.is_true r.timed-out?)
            (assert.are.equal 9 r.signal))))))))

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

    (it "runs a direct argv without shell interpretation"
      (fn []
        ;; `$HOME` and the glob would be expanded by a shell; with :argv they
        ;; must reach the program verbatim.
        (let [r (process.run-captured {:argv ["printf" "%s|%s" "$HOME" "*.fnl"]})]
          (assert.are.equal 0 r.exit-code)
          (assert.are.equal "$HOME|*.fnl" r.output))))

    (it "passes :env through to the child"
      (fn []
        (let [r (process.run-captured {:argv ["sh" "-c" "printf %s \"$FEN_TEST_VAR\""]
                                       :env {:FEN_TEST_VAR "from-parent"}})]
          (assert.are.equal 0 r.exit-code)
          (assert.are.equal "from-parent" r.output))))

    (it "applies :cwd for argv spawns"
      (fn []
        (let [r (process.run-captured {:argv ["pwd"] :cwd "/tmp"})]
          (assert.are.equal 0 r.exit-code)
          ;; /tmp may be a symlink (e.g. macOS); just assert it resolved to a
          ;; tmp-ish absolute path rather than the test cwd.
          (assert.is_truthy (string.find r.output "tmp" 1 true)))))

    (it "requires :cmd or :argv"
      (fn []
        (let [(ok? err) (pcall process.run-captured {})]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err) ":cmd or :argv" 1 true)))))

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

    (it "closes popen pipes before rethrowing cooperative cancellation"
      (fn []
        (let [pipe (assert (io.popen "yes | head -c 200000" :r))
              (ok? err) (pcall process.read-pipe-close
                               pipe
                               (fn [] (error "cancel-read")))]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err) "cancel%-read")))))

    ;; Containment contract (issue #303): timeout/cancellation signals the
    ;; child's process group, so ordinary descendants that stay in the group
    ;; are killed, but a descendant that escapes the group (setsid) can
    ;; survive. These two tests pin both sides of that boundary.
    (it "kills an ordinary background descendant that stays in the group"
      (fn []
        (let [marker (os.tmpname)]
          (os.remove marker)
          ;; Background descendant in the same session/process group. The
          ;; parent stays alive (sleep 5) so the timeout fires and signals the
          ;; group; the descendant must be killed before it writes the marker.
          (let [cmd (.. "sh -c 'sleep 1; touch " marker "' & sleep 5")
                r (process.run-captured {:cmd cmd
                                         :timeout-seconds 0.2
                                         :kill-grace-ms 100})]
            (assert.is_true r.timed-out?)
            (process.sleep-ms 1200)
            (let [f (io.open marker :r)]
              (when f (f:close) (os.remove marker))
              (assert.is_nil f
                             "in-group descendant survived process-group kill"))
            (assert.is_false r.cancelled?)))))

    (it "documents that a setsid descendant escapes process-group containment"
      (fn []
        (if (not (have-cmd? :setsid))
            ;; setsid(1) is Linux/util-linux; skip on platforms without it.
            (assert.is_true true)
            (let [marker (os.tmpname)]
              (os.remove marker)
              ;; The descendant calls setsid, leaving the child's process
              ;; group. run-captured still reports a timeout, but cannot
              ;; reach the escaped descendant. This characterizes the known
              ;; boundary rather than a bug: whole-tree containment requires
              ;; the optional sandbox.
              (let [cmd (.. "setsid sh -c 'sleep 1; touch " marker
                            "' >/dev/null 2>&1 & wait")
                    r (process.run-captured {:cmd cmd
                                             :timeout-seconds 0.2
                                             :kill-grace-ms 100})]
                (assert.is_true r.timed-out?)
                (process.sleep-ms 1200)
                (let [f (io.open marker :r)]
                  (when f (f:close) (os.remove marker))
                  ;; The marker exists: the detached descendant survived.
                  ;; If a future sandbox contains it, tighten this assertion.
                  (assert.is_truthy
                    f
                    "setsid descendant unexpectedly contained; update the contract if intended")))))))

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
