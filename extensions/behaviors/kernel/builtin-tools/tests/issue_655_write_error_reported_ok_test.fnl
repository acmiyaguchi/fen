;; Probe for #655: `write` reports success when the write fails (ENOSPC).
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "issue #655"
          (fn []
            (it "a write to /dev/full reports ok"
                (fn []
                  (known-bug 655
                             (fn []
                               ;; /dev/full (Linux) fails every write with ENOSPC.
                               (let [probe (assert (io.open "/dev/full" :r)
                                                   "this probe needs /dev/full")]
                                 (probe:close))
                               (let [r (th.execute th.registry :write
                                                   {:path "/dev/full"
                                                    :content (string.rep "x"
                                                                         100)})]
                                 (and (not r.is-error?)
                                      (not= nil
                                            (string.find (th.first-text r.content)
                                                         "wrote 100 bytes" 1
                                                         true))))))))))
