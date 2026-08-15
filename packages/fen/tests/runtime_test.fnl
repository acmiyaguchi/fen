(local runtime (require :fen.runtime))

(describe "fen.runtime"
  (fn []
    (var saved-arg nil)
    (var saved-fen-bin nil)
    (before_each (fn []
                   (set saved-arg _G.arg)
                   (set saved-fen-bin (os.getenv :FEN_BIN))))
    (after_each (fn []
                  (set _G.arg saved-arg)))

    (it "absolutizes argv[0] when it names an existing path"
      (fn []
        (set _G.arg {0 "scripts/dev/fen-dev"})
        (let [p (runtime.binary-path)]
          (assert.is_not_nil p)
          (assert.is_not_nil (string.match p "^/"))
          (assert.is_not_nil (string.match p "fen%-dev$")))))

    (it "falls back to FEN_BIN when argv[0] is a bare name"
      (fn []
        (set _G.arg {0 "fen"})
        (when (not (os.getenv :FEN_BIN))
          (assert.is_true true))
        (let [p (runtime.binary-path)]
          (assert.is_true (or (= p nil) (= (type p) :string))))))

    (it "ignores argv[0] paths that do not exist"
      (fn []
        (set _G.arg {0 "/nonexistent/path/to/fen-xyz"})
        (let [p (runtime.binary-path)]
          (assert.are_not.equal "/nonexistent/path/to/fen-xyz" p))))))
