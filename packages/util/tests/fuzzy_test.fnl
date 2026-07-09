(local fuzzy (require :fen.util.fuzzy))

(describe "util.fuzzy"
  (fn []
    (it "scores ordered non-contiguous matches case-insensitively"
      (fn []
        (assert.is_number (fuzzy.score "gpt55" "openai/gpt-5.5"))
        (assert.is_number (fuzzy.score "SNT" "anthropic/claude-sonnet-4-6"))
        (assert.is_nil (fuzzy.score "zz" "openai/gpt-5.5"))))

    (it "ranks better fuzzy matches first"
      (fn []
        (let [items [{:name "anthropic/claude-haiku-4-5"}
                     {:name "anthropic/claude-sonnet-4-6"}
                     {:name "openai/gpt-5.5"}]
              ranked (fuzzy.ranked "snt" items #$1.name)]
          (assert.are.equal 1 (length ranked))
          (assert.are.equal "anthropic/claude-sonnet-4-6" (. ranked 1 :name)))))

    (it "preserves input order for empty queries"
      (fn []
        (let [items [:a :b :c]
              ranked (fuzzy.ranked "" items #(tostring $1))]
          (assert.are.same items ranked))))))
