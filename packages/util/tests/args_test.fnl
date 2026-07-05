(local args (require :fen.util.args))

(describe "fen.util.args"
  (fn []
    (it "extracts positional whitespace-delimited arguments"
      (fn []
        (assert.are.equal "one" (args.first-arg "  one two three"))
        (assert.are.equal "two" (args.nth-arg "one two three" 2))
        (assert.are.equal "three" (args.nth-arg "one two three" 3))
        (assert.is_nil (args.nth-arg "one" 2))
        (assert.is_nil (args.nth-arg "one" nil))
        (assert.is_nil (args.nth-arg "one" 0))
        (assert.is_nil (args.nth-arg "one" -1))))

    (it "returns trimmed rest args after the first token"
      (fn []
        (assert.are.equal "two three" (args.rest-args "one two three"))
        (assert.are.equal "two three" (args.rest-args "  one   two three  "))
        (assert.are.equal "" (args.rest-args "one"))
        (assert.are.equal "" (args.rest-args nil))))

    (it "preserves the legacy rest-after-first nil/no-trim behavior"
      (fn []
        (assert.are.equal "two  " (args.rest-after-first "one two  "))
        (assert.is_nil (args.rest-after-first "one"))))))
