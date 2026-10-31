;; Probe for #656: a cancelled edit leaves files changed and reports "cancelled".
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "issue #656"
          (fn []
            (it "a cancel between the files of a batch leaves the first one written"
                (fn []
                  (known-bug 656
                             (fn []
                               (with-tmpdir [dir]
                                 (let [a (.. dir "/a")
                                       b (.. dir "/b")
                                       edits [{:old_string "foo"
                                               :new_string "bar"}]]
                                   (h.write-file a "foo\n")
                                   (h.write-file b "foo\n")
                                   (let [(ok? _) (pcall th.execute-coop
                                                        th.registry :edit
                                                        {:files [{:path a
                                                                  : edits}
                                                                 {:path b
                                                                  : edits}]}
                                                        (fn []
                                                          (when (= (h.read-file a)
                                                                   "bar\n")
                                                            (error :CANCEL))))]
                                     (and (not ok?) (= "bar\n" (h.read-file a))
                                          (= "foo\n" (h.read-file b))))))))))
            (it "a cancel at the yield after the commit hides a completed edit"
                (fn []
                  (known-bug 656
                             (fn []
                               (with-tmpdir [dir]
                                 (let [f (.. dir "/f")]
                                   (h.write-file f "foo\n")
                                   (let [(ok? _) (pcall th.execute-coop
                                                        th.registry :edit
                                                        {:path f
                                                         :edits [{:old_string "foo"
                                                                  :new_string "bar"}]}
                                                        (fn []
                                                          (when (= (h.read-file f)
                                                                   "bar\n")
                                                            (error :CANCEL))))]
                                     (and (not ok?) (= "bar\n" (h.read-file f))))))))))))
