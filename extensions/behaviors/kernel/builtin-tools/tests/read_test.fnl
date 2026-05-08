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

(describe "core.tools.read"
  (fn []
    (it "reads existing file contents into a TextContent block"
      (fn []
        (with-tmpfile [path "hello world"]
          (let [r (execute registry :read {:path path})]
            (assert.is_false r.is-error?)
            (assert.are.equal "hello world" (first-text r.content))))))

    (it "is-error? for missing path arg"
      (fn []
        (let [r (execute registry :read {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'path'")))))

    (it "is-error? for nonexistent path"
      (fn []
        (let [r (execute registry :read
                                {:path "/no/such/path/fen-test"})]
          (assert.is_true r.is-error?))))))

(describe "core.tools.read offset/limit"
  (fn []
    (it "slices [offset, offset+limit) of file lines"
      (fn []
        (with-tmpfile [path "one\ntwo\nthree\nfour\nfive\n"]
          (let [r (execute registry :read
                                  {:path path :offset 2 :limit 2})]
            (assert.is_false r.is-error?)
            (assert.are.equal "two\nthree" (first-text r.content))))))

    (it "returns empty content when offset is past the end"
      (fn []
        (with-tmpfile [path "alpha\nbeta\n"]
          (let [r (execute registry :read
                                  {:path path :offset 99 :limit 5})]
            (assert.is_false r.is-error?)
            (assert.are.equal "" (first-text r.content))))))

    (it "accepts float-looking integer offset/limit args"
      (fn []
        (with-tmpfile [path "one\ntwo\nthree\n"]
          (let [r (execute registry :read
                                  {:path path :offset 2.0 :limit 1.0})]
            (assert.is_false r.is-error?)
            (assert.are.equal "two" (first-text r.content))))))

    (it "is-error? when single and batched read shapes are both provided"
      (fn []
        (let [r (execute registry :read
                                {:path "/tmp/a" :paths ["/tmp/b"]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "either 'path' or 'paths'" 1 true)))))

    (it "is-error? for empty paths array"
      (fn []
        (let [r (execute registry :read {:paths []})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "missing 'paths'" 1 true)))))

    (it "reads multiple paths in one batched call with headers"
      (fn []
        (with-tmpfile [a "alpha"]
          (with-tmpfile [b "one\ntwo\nthree\n"]
            (let [r (execute registry :read
                                    {:paths [a {:path b :offset 2 :limit 1}]})]
              (assert.is_false r.is-error?)
              (let [text (first-text r.content)]
                (assert.is_truthy (string.find text (.. "==> " a " <==") 1 true))
                (assert.is_truthy (string.find text "alpha" 1 true))
                (assert.is_truthy (string.find text (.. "==> " b " <==") 1 true))
                (assert.is_truthy (string.find text "two" 1 true))
                (assert.is_falsy (string.find text "three" 1 true))))))))

    (it "includes missing-file errors inline in batched read results"
      (fn []
        (with-tmpfile [a "alpha"]
          (let [missing "/no/such/path/fen-read-batch-test"
                r (execute registry :read {:paths [a missing]})]
            (assert.is_false r.is-error?)
            (let [text (first-text r.content)]
              (assert.is_truthy (string.find text (.. "==> " a " <==") 1 true))
              (assert.is_truthy (string.find text (.. "==> " missing " <==") 1 true))
              (assert.is_truthy (string.find text "error:" 1 true)))))))

  ))

