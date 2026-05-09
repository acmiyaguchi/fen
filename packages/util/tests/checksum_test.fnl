(local checksum (require :fen.util.checksum))

(fn with-package-path [path f]
  (let [old package.path]
    (set package.path path)
    (let [(ok? result) (xpcall f debug.traceback)]
      (set package.path old)
      (if ok? result (error result)))))

(describe "fen.util.checksum.module-path"
  (fn []
    (it "finds Fennel source through the dev-path .fnl analogue of package.path"
      (fn []
        (with-package-path
          "./packages/util/tests/fixtures/checksum/?.lua"
          (fn []
            (assert.are.equal
              "./packages/util/tests/fixtures/checksum/sample/mod.fnl"
              (checksum.module-path :sample.mod))))))))
