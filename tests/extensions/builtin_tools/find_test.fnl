;; Tool-related test cases.

(local th (require :tool_test_helpers))
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
(import-macros {: with-tmpdir : with-tmpfile} :test_macros)

(after_each (fn [] (h.assert-no-leaks!)))

(describe "core.tools.find"
  (fn []
    (it "locates files matching a glob"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/needle.fnl") "")
          (h.write-file (.. dir "/other.lua") "")
          (let [r (execute registry :find
                                  {:pattern "*.fnl" :path dir})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "needle%.fnl"))
            (assert.is_falsy (string.find (first-text r.content) "other%.lua"))))))

    (it "accepts float-looking integer limit args"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.fnl") "")
          (h.write-file (.. dir "/b.fnl") "")
          (let [r (execute registry :find
                                  {:pattern "*.fnl" :path dir :limit 1.0})
                lines []]
            (assert.is_false r.is-error?)
            (assert.is_falsy (string.find (first-text r.content) "invalid number"))
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 1 (length lines))))))

    (it "is-error? for missing pattern"
      (fn []
        (let [r (execute registry :find {:path "."})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'pattern'")))))))

