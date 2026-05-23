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

(fn with-process-stub [mod-name f]
  (let [old-process (. package.loaded :fen.util.process)
        old-mod (. package.loaded mod-name)
        stub-called? {:value false}
        stub {:read-pipe-coop
              (fn [pipe yield-fn]
                (set stub-called?.value true)
                (when yield-fn (yield-fn))
                (or (pipe:read :*a) ""))
              :read-pipe-close
              (fn [pipe yield-fn]
                (set stub-called?.value true)
                (when yield-fn (yield-fn))
                (let [out (or (pipe:read :*a) "")]
                  (pipe:close)
                  out))}]
    (tset package.loaded :fen.util.process stub)
    (tset package.loaded mod-name nil)
    (let [(ok? result) (xpcall #(f (require mod-name)
                                   (fn [] stub-called?.value))
                               debug.traceback)]
      (tset package.loaded :fen.util.process old-process)
      (tset package.loaded mod-name old-mod)
      (if ok? result (error result)))))

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
          (assert.is_truthy (string.find (first-text r.content) "missing 'pattern'")))))

    (it "uses cooperative pipe drain when a yield-fn is provided"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/needle.fnl") "")
          (var yields 0)
          (with-process-stub
            :fen.extensions.builtin_tools.find
            (fn [find-tool stub-called?]
              (let [r (find-tool.execute {:pattern "*.fnl" :path dir}
                                         nil
                                         (fn [] (set yields (+ yields 1))))]
                (assert.is_false r.is-error?)
                (assert.is_truthy (string.find (first-text r.content) "needle%.fnl"))
                (assert.is_true (stub-called?))
                (assert.are.equal 1 yields)))))))))

