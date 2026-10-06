(local prompt-source (require :fen.prompt_source))
(local cli-help (require :fen.cli_help))
(local testing (require :fen.testing))

(fn contains? [s needle]
  (not= nil (string.find s needle 1 true)))

(describe "shared CLI prompt sources"
          (fn []
            (it "reads a prompt file and stdin using session-send semantics"
                (fn []
                  (let [tmp (testing.make-tmpdir)
                        path (.. tmp "/prompt.md")
                        _ (testing.write-file path "long\nobjective\n")
                        (file-prompt file-error) (prompt-source.read {:prompt-file path}
                                                                     nil)
                        original io.read
                        _ (set io.read (fn [_] "stdin objective"))
                        (stdin-prompt stdin-error) (prompt-source.read {:prompt "-"}
                                                                       nil)]
                    (set io.read original)
                    (testing.rmtree tmp)
                    (assert.is_nil file-error)
                    (assert.are.equal "long\nobjective\n" file-prompt)
                    (assert.is_nil stdin-error)
                    (assert.are.equal "stdin objective" stdin-prompt))))
            (it "counts mutually exclusive objective sources"
                (fn []
                  (assert.are.equal 0 (prompt-source.count {} nil))
                  (assert.are.equal 1 (prompt-source.count {:prompt "-"} nil))
                  (assert.are.equal 1
                                    (prompt-source.count {:prompt-file "x"} nil))
                  (assert.are.equal 1 (prompt-source.count {} "inline"))
                  (assert.are.equal 2
                                    (prompt-source.count {:prompt-file "x"}
                                                         "inline"))))
            (it "documents goal prompt sources and retries in focused help"
                (fn []
                  (let [goal (cli-help.for-subcommand :goal)
                        top (cli-help.top-level)]
                    (assert.is_truthy (contains? goal "--prompt-file PATH"))
                    (assert.is_truthy (contains? goal "--prompt -"))
                    (assert.is_truthy (contains? top
                                                 "Provider HTTP attempts for transient failures")))))))
