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

(describe "core.tools.grep"
  (fn []
    (it "finds a pattern across files in a directory"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "hello world\n")
          (h.write-file (.. dir "/b.txt") "goodbye\n")
          (let [r (execute registry :grep
                                  {:pattern "hello" :path dir})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "hello world"))
            (assert.is_falsy (string.find (first-text r.content) "goodbye"))))))

    (it "ignore_case matches across cases"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "Hello\n")
          (let [r (execute registry :grep
                                  {:pattern "hello" :path dir :ignore_case true})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "Hello"))))))

    (it "literal treats regex chars as text"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "a.b\n")
          (h.write-file (.. dir "/b.txt") "aXb\n")
          (let [r (execute registry :grep
                                  {:pattern "a.b" :path dir :literal true})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "a%.b"))
            (assert.is_falsy (string.find (first-text r.content) "aXb"))))))

    (it "accepts float-looking integer context/limit args"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "before\nneedle\nafter\n")
          (let [r (execute registry :grep
                                  {:pattern "needle" :path dir :context 1.0 :limit 2.0})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "needle"))
            (assert.is_falsy (string.find (first-text r.content) "invalid number"))))))

    (it "is-error? for missing pattern"
      (fn []
        (let [r (execute registry :grep {:path "."})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'pattern'")))))

    (it "uses cooperative pipe drain when a yield-fn is provided"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "hello world\n")
          (var yields 0)
          (with-process-stub
            :fen.extensions.builtin_tools.grep
            (fn [grep stub-called?]
              (let [r (grep.execute {:pattern "hello" :path dir}
                                    nil
                                    (fn [] (set yields (+ yields 1))))]
                (assert.is_false r.is-error?)
                (assert.is_truthy (string.find (first-text r.content) "hello world"))
                (assert.is_true (stub-called?))
                (assert.are.equal 1 yields)))))))))

