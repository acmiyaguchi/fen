(local h (require :test_helpers))
(import-macros {: with-tmpdir : with-tmpfile} :test_macros)

(describe "test_helpers temp cleanup"
  (fn []
    (it "rmtree only removes owned temp roots"
      (fn []
        (let [dir (h.make-tmpdir)
              path (.. dir "/nested/file.txt")]
          (h.write-file path "ok")
          (assert.are.equal "ok" (h.read-file! path))
          (h.rmtree dir)
          (assert.is_nil (h.read-file path)))
        (let [(ok? err) (pcall h.rmtree "/tmp/not-owned-by-fen-tests")]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err) "unowned temp root" 1 true)))))

    (it "rm-file only removes owned temp files"
      (fn []
        (let [path (h.make-tmpfile "ok")]
          (assert.are.equal "ok" (h.read-file! path))
          (h.rm-file path)
          (assert.is_nil (h.read-file path)))
        (let [(ok? err) (pcall h.rm-file "/tmp/not-owned-fen-file")]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err) "unowned temp file" 1 true)))))

    (it "with-tmpdir cleans up after the body"
      (fn []
        (var captured nil)
        (with-tmpdir [dir]
          (set captured dir)
          (h.write-file (.. dir "/file.txt") "ok")
          (assert.are.equal "ok" (h.read-file! (.. dir "/file.txt"))))
        (assert.is_nil (h.read-file (.. captured "/file.txt")))))

    (it "with-tmpfile cleans up after the body"
      (fn []
        (var captured nil)
        (with-tmpfile [path "ok"]
          (set captured path)
          (assert.are.equal "ok" (h.read-file! path)))
        (assert.is_nil (h.read-file captured))))

    (it "assert-no-leaks! passes after scoped fixtures clean up"
      (fn []
        (h.assert-no-leaks!)))

    (it "stub-getenv! delegates to the original getenv and restores"
      (fn []
        (let [orig-home (os.getenv :HOME)]
          (h.stub-getenv!
            (fn [name orig]
              (if (= name :FEN_TEST_ENV) "stubbed"
                  (orig name))))
          (assert.are.equal "stubbed" (os.getenv :FEN_TEST_ENV))
          (assert.are.equal orig-home (os.getenv :HOME))
          (h.restore-getenv!)
          (assert.is_nil (os.getenv :FEN_TEST_ENV))
          (assert.are.equal orig-home (os.getenv :HOME)))))))
