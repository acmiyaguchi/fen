(local flags (require :fen.cli_flags))

(describe "CLI flag suggestions"
  (fn []
    (it "limits typo suggestions to a short edit distance"
      (fn []
        (assert.is_nil (flags.nearest-flag "--bogus-flag" :top))
        (assert.are.equal "unknown option: --bogus-flag\n"
                          (flags.unknown-message "--bogus-flag" :top))
        (assert.are.equal "--model" (flags.nearest-flag "--modle" :top))
        (assert.are.equal "unknown option: --modle\ndid you mean --model?\n"
                          (flags.unknown-message "--modle" :top))))

    (it "suggests a real flag when the typed option is its prefix"
      (fn []
        (assert.are.equal "--model" (flags.nearest-flag "--mod" :top))))))
