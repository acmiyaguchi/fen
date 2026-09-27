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

    (it "pins approximate match results and scores"
      (fn []
        ;; Values recorded from the pre-#547 full-matrix DP; the two-row DP and length early-out must not change them.
        (each [_ [pattern text max-errors expected score]
               (ipairs [["provider" "provdier interface" 2 {:start 1 :end 8 :errors 2} 829]
                        ["provider" "provid" 2 {:start 1 :end 6 :errors 2} 829]
                        ["provider" "provi" 2 nil nil]
                        ["abcd" "ab" 2 {:start 1 :end 2 :errors 2} 829]
                        ["xy" "yx" 1 {:start 1 :end 1 :errors 1} 929]
                        ["session" "a sesion b sessoin" nil {:start 2 :end 8 :errors 1} 898]
                        ["backend" "bakend backedn" nil {:start 1 :end 6 :errors 1} 929]
                        ["ToolResultMessage" "types/toolresultmesage.fnl" nil
                         {:start 6 :end 22 :errors 1} 894]
                        ["docs" "distant object control status" nil nil 103]])]
          (let [c (bitap.compile pattern (when max-errors {:max-errors max-errors}))
                m (bitap.match c text)]
            (if expected
                (assert.are.same {:matched? true
                                  :start expected.start
                                  :end expected.end
                                  :errors expected.errors}
                                 m)
                (assert.is_nil m))
            (assert.are.equal score (bitap.score c text))))))

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
