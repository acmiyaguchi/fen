;; Regression for #658: edit counts overlapping occurrences of old_string, so
;; an old_string that occurs twice (overlapping) is rejected as not unique.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "edit uniqueness (#658)"
          (fn []
            (it "rejects an old_string whose two occurrences overlap"
                (fn []
                  (with-tmpdir [dir]
                    (let [f (.. dir "/f")]
                      (h.write-file f "}\n}\n}\n")
                      (let [r (th.execute th.registry :edit
                                          {:path f
                                           :edits [{:old_string "}\n}"
                                                    :new_string "X"}]})
                            out (th.first-text r.content)]
                        (assert.is_true r.is-error?)
                        (assert.is_truthy (string.find out
                                                       "not unique (2 matches)"
                                                       1 true))
                        (assert.is_truthy (string.find out "line 1:" 1 true))
                        (assert.is_truthy (string.find out "line 2:" 1 true))
                        (assert.are.equal "}\n}\n}\n" (h.read-file f)))))))
            (it "still accepts a pattern that occurs once"
                (fn []
                  (with-tmpdir [dir]
                    (let [f (.. dir "/f")]
                      (h.write-file f "aab")
                      (let [r (th.execute th.registry :edit
                                          {:path f
                                           :edits [{:old_string "aa"
                                                    :new_string "X"}]})]
                        (assert.is_false r.is-error?)
                        (assert.are.equal "Xb" (h.read-file f)))))))))
