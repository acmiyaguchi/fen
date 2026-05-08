;; Macros for scoped test fixtures. Kept separate from fen.testing so
;; import-macros does not compile runtime helper functions in macro scope.

(fn body-form [body]
  (if (= (length body) 0)
      `(do)
      (= (length body) 1)
      (. body 1)
      (let [form `(do)]
        (each [_ expr (ipairs body)]
          (table.insert form expr))
        form)))

;; @doc fen.testing.macros.with-tmpdir
;; kind: function
;; signature: (with-tmpdir [name] body...) -> macro-form
;; summary: Macro that creates an owned temp directory for a test body and always removes it afterward.
;; tags: testing macros temp
(fn with-tmpdir [binding & body]
  (let [name (. binding 1)
        wrapped (body-form body)]
    `(let [helpers# (require :fen.testing)
           ,name (helpers#.make-tmpdir)]
       (let [(ok# result#) (pcall (fn [] ,wrapped))]
         (helpers#.rmtree ,name)
         (if ok# result# (error result#))))))

;; @doc fen.testing.macros.with-tmpfile
;; kind: function
;; signature: (with-tmpfile [name content] body...) -> macro-form
;; summary: Macro that creates an owned temp file with content for a test body and always removes it afterward.
;; tags: testing macros temp
(fn with-tmpfile [binding & body]
  (let [name (. binding 1)
        content (. binding 2)
        wrapped (body-form body)]
    `(let [helpers# (require :fen.testing)
           ,name (helpers#.make-tmpfile ,content)]
       (let [(ok# result#) (pcall (fn [] ,wrapped))]
         (helpers#.rm-file ,name)
         (if ok# result# (error result#))))))

{: with-tmpdir
 : with-tmpfile}
