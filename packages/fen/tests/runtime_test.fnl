(local runtime (require :fen.runtime))

(describe "fen.runtime"
          (fn []
            (var saved-arg nil)
            (var saved-getenv nil)
            (before_each (fn []
                           (set saved-arg _G.arg)
                           (set saved-getenv os.getenv)))
            (after_each (fn []
                          (set _G.arg saved-arg)
                          (set os.getenv saved-getenv)))
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
                  (set os.getenv
                       (fn [name]
                         (if (= name "FEN_BIN")
                             nil
                             (saved-getenv name))))
                  (let [probe (io.open "/proc/self/exe" :r)]
                    (when probe
                      (probe:close)
                      (let [proc (io.popen "readlink /proc/$PPID/exe 2>/dev/null"
                                           :r)]
                        (assert.is_not_nil proc)
                        (let [expected (proc:read :*l)]
                          (proc:close)
                          (assert.is_not_nil expected)
                          (let [basename (string.match expected "([^/]+)$")]
                            (assert.is_not_nil basename)
                            (assert.are_not.equal "readlink" basename)
                            (assert.are_not.equal "coreutils" basename))
                          (set _G.arg {0 "fen"})
                          (assert.are.equal expected (runtime.binary-path))))))))
            (it "ignores argv[0] paths that do not exist"
                (fn []
                  (set _G.arg {0 "/nonexistent/path/to/fen-xyz"})
                  (let [p (runtime.binary-path)]
                    (assert.are_not.equal "/nonexistent/path/to/fen-xyz" p))))))
