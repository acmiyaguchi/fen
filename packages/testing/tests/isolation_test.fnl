(local path (require :fen.util.path))

(fn under? [dir root]
  (= (string.sub dir 1 (+ (length root) 1)) (.. root "/")))

(describe "test run isolation"
  (fn []
    (it "resolves every XDG home and HOME under the per-run temp root"
      (fn []
        (let [root (os.getenv :FEN_TEST_HOME)]
          (assert.is_truthy root "run tests through scripts/test/run-tests.sh")
          (each [_ dir (ipairs [(path.home) (path.config-home)
                                (path.state-home) (path.data-home)
                                (os.getenv :XDG_CACHE_HOME)])]
            (assert.is_true (under? dir root) dir)))))))
