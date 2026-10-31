;; Probe for #652: the provider-side cap drops bash's exit/timeout tag.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local {: known-bug} (require :fen.testing))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "issue #652"
          (fn []
            (it "escaped control bytes push [exit 7] past the result cap"
                (fn []
                  (known-bug 652
                             (fn []
                               (with-tmpdir [dir]
                                 (let [f (.. dir "/ctl")]
                                   (h.write-file f (string.rep "\001" 30000))
                                   (let [r (th.execute th.registry :bash
                                                       {:cmd (.. "cat " f
                                                                 "; exit 7")})
                                         text (th.first-text r.content)]
                                     (and (= 7 r.details.exit-code)
                                          (= nil
                                             (string.find text "[exit 7]" 1
                                                          true))))))))))))
