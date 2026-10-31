;; Regression for #652 and #653: bash's result keeps its exit/timeout trailer
;; under the provider-side cap, and its tail cut starts on a UTF-8 boundary.
;; See spec/tools/FINDINGS.md.
(local th (require :fen.testing.tools))
(local text (require :fen.util.text))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(fn last-line [s]
  (string.match s "([^\n]*)$"))

(describe "bash result envelope"
          (fn []
            (it "keeps [exit 7] last when escaped control bytes exceed the cap (#652)"
                (fn []
                  (with-tmpdir [dir]
                    (let [f (.. dir "/ctl")]
                      (h.write-file f (string.rep "\001" 30000))
                      (let [r (th.execute th.registry :bash
                                          {:cmd (.. "cat " f "; exit 7")})
                            out (th.first-text r.content)]
                        (assert.are.equal 7 r.details.exit-code)
                        (assert.is_true r.is-error?)
                        (assert.are.equal "[exit 7]" (last-line out))
                        (assert.is_true (<= (length out)
                                            (text.default-tool-result-max-bytes)))
                        (assert.is_truthy (string.find out
                                                       "[truncated: kept tail" 1
                                                       true))
                        (assert.is_truthy (string.find out
                                                       "unsafe bytes escaped" 1
                                                       true)))))))
            (it "sends a small result whole, trailer last"
                (fn []
                  (let [r (th.execute th.registry :bash
                                      {:cmd "printf 'a\\001b\\n'; exit 3"})
                        out (th.first-text r.content)]
                    (assert.are.equal "a\\x01b\n\n[fen: tool output sanitized: 1 unsafe bytes escaped]\n[exit 3]"
                                      out))))
            (it "starts the tail on a character boundary (#653)"
                (fn []
                  (with-tmpdir [dir]
                    (let [f (.. dir "/utf8")]
                      ;; 60001 bytes; the 50 KiB tail starts at an odd offset.
                      (h.write-file f (.. (string.rep "é" 30000) "\n"))
                      (let [r (th.execute th.registry :bash
                                          {:cmd (.. "cat " f)})
                            out (th.first-text r.content)
                            body (string.match out "^[^\n]*\n(.*)$")]
                        (assert.is_falsy (string.find out "\\x" 1 true))
                        (assert.is_falsy (string.find out "sanitized" 1 true))
                        (assert.are.equal "é" (string.sub body 1 2))
                        (assert.are.equal "[exit 0]" (last-line out)))))))))
