;; Probe for #657: `edit` overwrites a change made while it yielded.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "issue #657"
          (fn []
            (it "a write landing at the first yield is silently reverted"
                (fn []
                  (known-bug 657
                             (fn []
                               (with-tmpdir [dir]
                                 (let [f (.. dir "/f")]
                                   (h.write-file f "x = 1\ny = 2\n")
                                   (var done? false)
                                   (let [r (th.execute-coop th.registry :edit
                                                            {:path f
                                                             :edits [{:old_string "x = 1"
                                                                      :new_string "x = 10"}]}
                                                            (fn []
                                                              ;; another process's write, outside fen's mutex
                                                              (when (not done?)
                                                                (set done? true)
                                                                (h.write-file f
                                                                              "x = 1\ny = 2\nz = 3\n"))))]
                                     (and (not r.is-error?)
                                          (= "x = 10\ny = 2\n" (h.read-file f))))))))))))
