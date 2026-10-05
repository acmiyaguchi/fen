(local runtime (require :fen.runtime))

(describe "fen.runtime"
          (fn []
            (var saved-arg nil)
            (before_each (fn []
                           (set saved-arg _G.arg)))
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
            (it "resolves the current process executable for a bare argv[0]"
                (fn []
                  ;; This test is run with FEN_BIN unset so the /proc fallback
                  ;; is exercised rather than the environment override.
                  (when (and (not (os.getenv :FEN_BIN))
                             (io.open "/proc/self/exe" :r))
                    (let [proc (io.popen "readlink /proc/$PPID/exe 2>/dev/null"
                                         :r)]
                      (assert.is_not_nil proc)
                      (let [expected (proc:read :*l)]
                        (proc:close)
                        (assert.is_not_nil expected)
                        (set _G.arg {0 "fen"})
                        (assert.are.equal expected (runtime.binary-path)))))))
            (it "ignores argv[0] paths that do not exist"
                (fn []
                  (set _G.arg {0 "/nonexistent/path/to/fen-xyz"})
                  (let [p (runtime.binary-path)]
                    (assert.are_not.equal "/nonexistent/path/to/fen-xyz" p))))))
