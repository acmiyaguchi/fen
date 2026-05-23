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

(describe "core.tools.ls"
  (fn []
    (it "lists entries in a directory"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/alpha") "")
          (h.write-file (.. dir "/beta") "")
          (let [r (execute registry :ls {:path dir})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "alpha"))
            (assert.is_truthy (string.find (first-text r.content) "beta"))))))

    (it "defaults to '.' when no path is given"
      (fn []
        (let [r (execute registry :ls {})]
          (assert.is_false r.is-error?))))

    (it "uses cooperative pipe drain when a yield-fn is provided"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/alpha") "")
          (var yields 0)
          (with-process-stub
            :fen.extensions.builtin_tools.ls
            (fn [ls-tool stub-called?]
              (let [r (ls-tool.execute {:path dir}
                                       nil
                                       (fn [] (set yields (+ yields 1))))]
                (assert.is_false r.is-error?)
                (assert.is_truthy (string.find (first-text r.content) "alpha"))
                (assert.is_true (stub-called?))
                (assert.are.equal 1 yields)))))))))

(describe "core.tools.ls limit"
  (fn []
    (it "truncates the listing to the requested limit"
      (fn []
        (with-tmpdir [dir]
          (each [_ name (ipairs ["a" "b" "c" "d" "e"])]
            (h.write-file (.. dir "/" name) ""))
          (let [r (execute registry :ls
                                  {:path dir :limit 2})
                lines []]
            (assert.is_false r.is-error?)
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 2 (length lines))))))

    (it "accepts float-looking integer limit args"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a") "")
          (h.write-file (.. dir "/b") "")
          (let [r (execute registry :ls
                                  {:path dir :limit 1.0})
                lines []]
            (assert.is_false r.is-error?)
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 1 (length lines))))))))

