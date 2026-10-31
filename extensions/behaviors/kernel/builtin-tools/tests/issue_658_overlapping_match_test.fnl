;; Probe for #658: `edit` accepts an old_string whose occurrences overlap.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "issue #658"
          (fn []
            (it "two overlapping matches count as one, and the edit is applied"
                (fn []
                  (known-bug 658
                             (fn []
                               (with-tmpdir [dir]
                                 (let [f (.. dir "/f")]
                                   (h.write-file f "}\n}\n}\n")
                                   (let [r (th.execute th.registry :edit
                                                       {:path f
                                                        :edits [{:old_string "}\n}"
                                                                 :new_string "X"}]})]
                                     (and (not r.is-error?)
                                          (= "X\n}\n" (h.read-file f))))))))))))
