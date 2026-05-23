;; Tool-related test cases.

(local th (require :fen.testing.tools))
(local tools th.tools)
(local extensions th.extensions)
(local registry th.registry)
(local types th.types)
(local json th.json)
(local h th.h)
(local read-file th.read-file)
(local first-text th.first-text)
(local execute th.execute)
(local execute-coop th.execute-coop)
(import-macros {: with-tmpdir : with-tmpfile} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "core.tools.write"
  (fn []
    (it "writes content and reports byte count"
      (fn []
        (with-tmpfile [path ""]
          (let [r (execute registry :write {:path path :content "abc"})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "wrote 3 bytes"))
            (assert.are.equal "abc" (read-file path))))))

    (it "is-error? for missing path arg"
      (fn []
        (let [r (execute registry :write {:content :x})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'path'")))))

    (it "yields while writing large content cooperatively"
      (fn []
        (with-tmpfile [path ""]
          (var yields 0)
          (let [content (string.rep "x" 40000)
                r (execute-coop registry :write {:path path :content content}
                                      (fn [] (set yields (+ yields 1))))]
            (assert.is_false r.is-error?)
            (assert.are.equal content (read-file path))
            (assert.is_true (> yields 0))))))))

(describe "core.tools.write parent dir"
  (fn []
    (it "auto-creates the parent directory"
      (fn []
        (with-tmpdir [base]
          (let [path (.. base "/nested/deeper/hello.txt")
                r (execute registry :write
                                  {:path path :content "hi"})]
            (assert.is_false r.is-error?)
            (assert.are.equal "hi" (read-file path))))))))
