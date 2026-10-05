(local testing (require :fen.testing))

(local FEN-CMD "scripts/test/fen-src")
(local MOCK "--extension extensions/adapters/providers/mock --provider mock")

(fn contains? [s needle]
  (not= nil (string.find s needle 1 true)))

(fn run [input args]
  (let [tmp (testing.make-tmpdir)
        prefix (.. "XDG_CONFIG_HOME=" (testing.shellquote (.. tmp "/config"))
                   " XDG_STATE_HOME=" (testing.shellquote (.. tmp "/state")) " ")
        command (.. (if input
                        (.. "printf %s " (testing.shellquote input) " | ")
                        "") prefix FEN-CMD " goal " MOCK
                    " --max-iterations 1 " args " 2>&1")
        pipe (assert (io.popen command))
        output (pipe:read :*a)
        (ok _why code) (pipe:close)]
    (testing.rmtree tmp)
    (values output (if (= ok true) 0 (or code 1)))))

(describe "fen goal prompt sources"
          (fn []
            (it "reads a multi-line objective from --prompt-file"
                (fn []
                  (let [tmp (testing.make-tmpdir)
                        path (.. tmp "/objective.md")
                        _ (testing.write-file path
                                              "file objective\nsecond line")
                        (output _) (run nil
                                        (.. "--prompt-file "
                                            (testing.shellquote path)))]
                    (testing.rmtree tmp)
                    (assert.is_truthy (contains? output
                                                 "Objective: file objective second line")
                                      output))))
            (it "accepts literal text with --prompt"
                (fn []
                  (let [(output _) (run nil "--prompt 'literal objective'")]
                    (assert.is_truthy (contains? output
                                                 "Objective: literal objective")
                                      output)
                    (assert.is_false (contains? output "only accepts - (stdin)")))))
            (it "reads its objective from --prompt - stdin"
                (fn []
                  (let [(output _) (run "stdin objective" "--prompt -")]
                    (assert.is_truthy (contains? output
                                                 "Objective: stdin objective")
                                      output))))
            (it "rejects combined sources and empty stdin with exit 2"
                (fn []
                  (let [(combined code) (run nil
                                             "--prompt-file /dev/null inline")
                        (empty empty-code) (run "" "--prompt -")]
                    (assert.are.equal 2 code)
                    (assert.is_truthy (contains? combined "choose exactly one")
                                      combined)
                    (assert.are.equal 2 empty-code)
                    (assert.is_truthy (contains? empty "non-empty objective")
                                      empty))))))
