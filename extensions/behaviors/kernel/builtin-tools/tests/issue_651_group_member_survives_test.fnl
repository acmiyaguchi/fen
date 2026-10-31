;; Probe for #651: a timed-out or cancelled bash call leaves a live process
;; in its own process group. See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
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

(describe "issue #651"
          (fn []
            (it "a TERM-ignoring group member outlives the timeout"
                (fn []
                  (known-bug 651
                             (fn []
                               (with-tmpdir [dir]
                                 (let [pidfile (.. dir "/PID")
                                       cmd (.. "sh -c 'trap \"\" TERM; echo $$ > "
                                               pidfile "; exec sleep 30' & wait")
                                       r (process.run-captured {:cmd cmd
                                                                :timeout-seconds 0.2})
                                       pid (read-pid pidfile)
                                       survived? (and pid (alive? pid))]
                                   (kill! pid)
                                   (and r.timed-out? (not (not survived?)))))))))
            (it "a cancel after the leader is reaped misses the member"
                (fn []
                  (known-bug 651
                             (fn []
                               (with-tmpdir [dir]
                                 (let [pidfile (.. dir "/PID")
                                       cmd (.. "sleep 30 & echo $! > " pidfile)]
                                   (var seen nil)
                                   (let [yield-fn (fn []
                                                    (when (and (not seen)
                                                               (read-pid pidfile))
                                                      (set seen
                                                           (clock.monotonic-ms)))
                                                    (when (and seen
                                                               (> (- (clock.monotonic-ms)
                                                                     seen)
                                                                  60))
                                                      (error :CANCEL)))
                                         (ok? _) (pcall th.execute-coop
                                                        th.registry :bash
                                                        {:cmd cmd} yield-fn)
                                         pid (read-pid pidfile)
                                         survived? (and pid (alive? pid))]
                                     (kill! pid)
                                     (and (not ok?) (not (not survived?))))))))))))
