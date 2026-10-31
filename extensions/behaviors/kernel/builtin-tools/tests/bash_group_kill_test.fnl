;; Regression for #651: a timed-out or cancelled bash call SIGKILLs its whole
;; process group, even after the leader is reaped, so no member outlives it.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local process (require :fen.util.process))
(local clock (require :fen.util.clock))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(fn sh-ok? [cmd]
  (let [r (os.execute cmd)]
    (or (= r true) (= r 0))))

(fn read-pid [path]
  (let [f (io.open path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        (tonumber (string.match s "%d+"))))))

(fn alive? [pid]
  (sh-ok? (.. "kill -0 " pid " 2>/dev/null")))

(fn kill! [pid]
  (when pid
    (sh-ok? (.. "kill -9 " pid " 2>/dev/null"))))

(fn dead-soon? [pid]
  ;; SIGKILL delivery is asynchronous; allow the kernel a moment.
  (var alive (alive? pid))
  (let [until-ms (+ (clock.monotonic-ms) 1000)]
    (while (and alive (< (clock.monotonic-ms) until-ms))
      (clock.sleep-ms 10)
      (set alive (alive? pid))))
  (not alive))

(describe "bash process-group containment (#651)"
          (fn []
            (it "kills a TERM-ignoring group member when the timeout fires"
                (fn []
                  (with-tmpdir [dir]
                    (let [pidfile (.. dir "/PID")
                          cmd (.. "sh -c 'trap \"\" TERM; echo $$ > " pidfile
                                  "; exec sleep 30' & wait")
                          r (process.run-captured {: cmd :timeout-seconds 0.2})
                          pid (read-pid pidfile)
                          dead? (and pid (dead-soon? pid))]
                      (kill! pid)
                      (assert.is_true r.timed-out?)
                      (assert.is_truthy pid)
                      (assert.is_true dead?
                                      "TERM-ignoring member outlived the timeout")))))
            (it "kills a member that holds the pipe when cancel lands after the leader is reaped"
                (fn []
                  (with-tmpdir [dir]
                    (let [pidfile (.. dir "/PID")
                          cmd (.. "sleep 30 & echo $! > " pidfile)]
                      (var seen nil)
                      (let [yield-fn (fn []
                                       (when (and (not seen) (read-pid pidfile))
                                         (set seen (clock.monotonic-ms)))
                                       (when (and seen
                                                  (> (- (clock.monotonic-ms)
                                                        seen)
                                                     60))
                                         (error :CANCEL 0)))
                            (ok? err) (pcall th.execute-coop th.registry :bash
                                             {: cmd} yield-fn)
                            pid (read-pid pidfile)
                            dead? (and pid (dead-soon? pid))]
                        (kill! pid)
                        (assert.is_false ok?)
                        (assert.are.equal :CANCEL err)
                        (assert.is_truthy pid)
                        (assert.is_true dead?
                                        "group member outlived the cancel"))))))
            (it "leaves a background member alone after a normal exit"
                (fn []
                  (with-tmpdir [dir]
                    (let [pidfile (.. dir "/PID")
                          cmd (.. "sleep 30 >/dev/null 2>&1 & echo $! > "
                                  pidfile)
                          r (process.run-captured {: cmd})
                          pid (read-pid pidfile)
                          alive-after? (and pid (alive? pid))]
                      (kill! pid)
                      (assert.are.equal 0 r.exit-code)
                      (assert.is_true alive-after?
                                      "a normal exit must not signal the group")))))))
