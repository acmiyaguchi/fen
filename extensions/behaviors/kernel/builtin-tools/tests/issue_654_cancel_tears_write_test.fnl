;; Probe for #654: cancelling `write` mid-file leaves a torn file.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "issue #654"
          (fn []
            (it "a cancel at a chunk yield leaves neither the old nor the new content"
                (fn []
                  (known-bug 654
                             (fn []
                               (with-tmpdir [dir]
                                 (let [f (.. dir "/target")
                                       original "ORIGINAL CONTENT\n"
                                       content (string.rep "x" 40000)]
                                   (h.write-file f original)
                                   (var calls 0)
                                   (let [(ok? _) (pcall th.execute-coop
                                                        th.registry :write
                                                        {:path f : content}
                                                        (fn []
                                                          (set calls
                                                               (+ calls 1))
                                                          (when (= calls 4)
                                                            (error :CANCEL))))
                                         after (h.read-file f)]
                                     (and (not ok?) (not= after original)
                                          (not= after content)))))))))))
