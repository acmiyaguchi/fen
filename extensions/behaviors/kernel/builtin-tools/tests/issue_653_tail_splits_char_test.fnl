;; Probe for #653: bash's tail cap starts the output inside a UTF-8 character.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "issue #653"
          (fn []
            (it "the byte tail cut leaves an orphaned continuation byte"
                (fn []
                  (known-bug 653
                             (fn []
                               (with-tmpdir [dir]
                                 (let [f (.. dir "/utf8")]
                                   ;; 60001 bytes; the 50 KiB tail starts at an odd offset.
                                   (h.write-file f
                                                 (.. (string.rep "é" 30000)
                                                     "\n"))
                                   (let [r (th.execute th.registry :bash
                                                       {:cmd (.. "cat " f)})
                                         text (th.first-text r.content)]
                                     (not= nil
                                           (string.find text "\\xA9é" 1 true)))))))))))
