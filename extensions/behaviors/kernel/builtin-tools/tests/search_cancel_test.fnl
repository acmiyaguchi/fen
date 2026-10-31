;; Regression for #659: a cancelled grep/find/ls SIGKILLs its process group
;; (it runs as a process job) instead of waiting in pclose for the child.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local clock (require :fen.util.clock))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(fn sh-ok? [cmd]
  (let [r (os.execute cmd)]
    (or (= r true) (= r 0))))

(describe "search tool cancel (#659)"
          (fn []
            (it "a cancelled grep stuck on a FIFO returns promptly"
                (fn []
                  (with-tmpdir [dir]
                    (let [fifo (.. dir "/fifo")]
                      (assert (sh-ok? (.. "mkfifo " (h.shellquote fifo))))
                      ;; A writer that would unblock grep only after 2 s.
                      (let [p (io.popen (.. "(sleep 2; echo x > "
                                            (h.shellquote fifo)
                                            ") >/dev/null 2>&1 & echo $!"))
                            writer (tonumber (p:read :*l))
                            _ (p:close)
                            t0 (clock.monotonic-ms)
                            (ok? err) (pcall th.execute-coop th.registry :grep
                                             {:pattern "x" :path fifo}
                                             (fn [] (error :CANCEL 0)))
                            blocked-ms (- (clock.monotonic-ms) t0)]
                        ;; The killed grep never opens the FIFO, so the writer is stuck in open().
                        (when writer
                          (sh-ok? (.. "kill -9 " writer " 2>/dev/null")))
                        (assert.is_false ok?)
                        (assert.are.equal :CANCEL err)
                        (assert.is_true (< blocked-ms 1000)
                                        (.. "cancel blocked for "
                                            (tostring blocked-ms) "ms")))))))
            (it "a cancelled find and ls also unwind"
                (fn []
                  (with-tmpdir [dir]
                    (each [_ [name args] (ipairs [[:find
                                                   {:pattern "*.x" :path dir}]
                                                  [:ls {:path dir}]])]
                      (let [(ok? err) (pcall th.execute-coop th.registry name
                                             args (fn [] (error :CANCEL 0)))]
                        (assert.is_false ok?)
                        (assert.are.equal :CANCEL err))))))))
