;; Probe for #659: a cancelled grep blocks the whole process until its child exits.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))
(local clock (require :fen.util.clock))

(fn sh-ok? [cmd]
  (let [r (os.execute cmd)]
    (or (= r true) (= r 0))))

(describe "issue #659"
          (fn []
            (it "cancel waits in pclose for a grep stuck on a FIFO"
                (fn []
                  (known-bug 659
                             (fn []
                               (with-tmpdir [dir]
                                 (let [fifo (.. dir "/fifo")]
                                   (assert (sh-ok? (.. "mkfifo " fifo)))
                                   ;; A writer that unblocks grep after 300 ms.
                                   (let [p (io.popen (.. "(sleep 0.3; echo x > "
                                                         fifo
                                                         ") >/dev/null 2>&1 & echo $!"))
                                         writer (tonumber (p:read :*l))
                                         _ (p:close)
                                         t0 (clock.monotonic-ms)
                                         (ok? _) (pcall th.execute-coop
                                                        th.registry :grep
                                                        {:pattern "x"
                                                         :path fifo}
                                                        (fn [] (error :CANCEL)))
                                         blocked-ms (- (clock.monotonic-ms) t0)]
                                     ;; If grep was killed instead, the writer is stuck in open().
                                     (when writer
                                       (sh-ok? (.. "kill -9 " writer
                                                   " 2>/dev/null")))
                                     (and (not ok?) (>= blocked-ms 250)))))))))))
