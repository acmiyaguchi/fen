(local flags (require :fen.cli_flags))

(describe "CLI flag suggestions"
          (fn []
            (it "limits typo suggestions to a short edit distance"
                (fn []
                  (assert.is_nil (flags.nearest-flag "--bogus-flag" :top))
                  (assert.are.equal "unknown option: --bogus-flag\n"
                                    (flags.unknown-message "--bogus-flag" :top))
                  (assert.are.equal "--model"
                                    (flags.nearest-flag "--modle" :top))
                  (assert.are.equal "unknown option: --modle\ndid you mean --model?\n"
                                    (flags.unknown-message "--modle" :top))))
            (it "suggests a real flag when the typed option is its prefix"
                (fn []
                  (assert.are.equal "--model" (flags.nearest-flag "--mod" :top))))))

(describe "--web-search mode choices"
          (fn []
            (local parse (require :fen.cli_parse))

            (fn consume [context value]
              (let [opts {}
                    flag (flags.find "--web-search" context)
                    (next-index err) (parse.consume! opts flag
                                                     ["--web-search" value] 1)]
                (values opts next-index err)))

            (it "accepts each mode on every command that takes it"
                (fn []
                  (each [_ context (ipairs [:top :goal :session-send])]
                    (each [_ mode (ipairs ["off" "cached" "live"])]
                      (let [(opts next-index err) (consume context mode)]
                        (assert.is_nil err)
                        (assert.are.equal 3 next-index)
                        (assert.are.equal mode opts.web-search))))))
            (it "rejects an unknown mode, naming the accepted ones"
                (fn []
                  (let [(opts next-index err) (consume :top "bogus")]
                    (assert.is_nil next-index)
                    (assert.is_nil opts.web-search)
                    (assert.are.equal "invalid --web-search: bogus (expected off, cached, live)"
                                      err))))
            (it "is not a flag for commands without a provider turn"
                (fn []
                  (assert.is_falsy (flags.find "--web-search" :list))
                  (assert.is_falsy (flags.find "--web-search" :session-new))))
            (it "validates settings values against the same mode list"
                (fn []
                  (let [flag (flags.find-any "--web-search")]
                    (assert.is_true (parse.valid-choice? flag "cached"))
                    (assert.is_false (parse.valid-choice? flag "on"))
                    (assert.is_false (parse.valid-choice? flag true))
                    ;; Flags without a choices list accept any value.
                    (assert.is_true (parse.valid-choice? (flags.find-any "--model")
                                                         "x")))))))
