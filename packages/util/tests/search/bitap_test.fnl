(local bitap (require :fen.util.search.bitap))

(describe "fen.util.search.bitap"
  (fn []
    (it "matches exact text"
      (fn []
        (let [c (bitap.compile "docs")
              m (bitap.match c "fen docs browser")]
          (assert.is_true m.matched?)
          (assert.are.equal 0 m.errors)
          (assert.are.equal 5 m.start))))

    (it "matches a small typo within max-errors"
      (fn []
        (let [c (bitap.compile "provider" {:max-errors 2})
              m (bitap.match c "provdier interface")]
          (assert.is_not_nil m)
          (assert.is_true (<= m.errors 2)))))

    (it "rejects matches outside max-errors"
      (fn []
        (let [c (bitap.compile "provider" {:max-errors 1})]
          (assert.is_nil (bitap.match c "session backend")))))

    (it "scores exact and prefix matches above scattered subsequences"
      (fn []
        (let [c (bitap.compile "docs")
              exact (bitap.score c "docs")
              prefix (bitap.score c "docs browser")
              scattered (bitap.score c "distant object control status")]
          (assert.is_true (> exact scattered))
          (assert.is_true (> prefix scattered)))))

    (it "case-folds by default"
      (fn []
        (let [c (bitap.compile "ToolResultMessage")]
          (assert.is_not_nil (bitap.match c "types/toolresultmessage")))))

    (it "supports case-sensitive mode"
      (fn []
        (let [c (bitap.compile "Tool" {:case-fold? false :max-errors 0})]
          (assert.is_nil (bitap.match c "tool")))))

    (it "handles empty patterns"
      (fn []
        (let [m (bitap.match (bitap.compile "") "anything")]
          (assert.is_true m.matched?)
          (assert.are.equal 0 m.errors))))))
