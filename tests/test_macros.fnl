;; Macros for scoped test fixtures. Kept separate from test_helpers so
;; import-macros does not compile runtime helper functions in macro scope.

(fn body-form [body]
  (if (= (length body) 1)
      (. body 1)
      (let [form `(do)]
        (each [_ expr (ipairs body)]
          (table.insert form expr))
        form)))

(fn with-tmpdir [binding & body]
  (let [name (. binding 1)
        wrapped (body-form body)]
    `(let [helpers# (require :test_helpers)
           ,name (helpers#.make-tmpdir)]
       (let [(ok# result#) (pcall (fn [] ,wrapped))]
         (helpers#.rmtree ,name)
         (if ok# result# (error result#))))))

(fn with-tmpfile [binding & body]
  (let [name (. binding 1)
        content (. binding 2)
        wrapped (body-form body)]
    `(let [helpers# (require :test_helpers)
           ,name (helpers#.make-tmpfile ,content)]
       (let [(ok# result#) (pcall (fn [] ,wrapped))]
         (helpers#.rm-file ,name)
         (if ok# result# (error result#))))))

{: with-tmpdir
 : with-tmpfile}
