(local checksum (require :fen.util.checksum))
(local h (require :fen.testing))

(fn with-package-path [path f]
  (let [old package.path]
    (set package.path path)
    (let [(ok? result) (xpcall f debug.traceback)]
      (set package.path old)
      (if ok? result (error result)))))

(describe "fen.util.checksum.file-fingerprint"
  (fn []
    (it "uses exact file contents so same-sized edits differ"
      (fn []
        (let [tmp (h.make-tmpdir)
              path (.. tmp "/source.fnl")]
          (h.write-file path "abc\n")
          (let [before (checksum.file-fingerprint path)]
            (h.write-file path "abd\n")
            (let [after (checksum.file-fingerprint path)]
              (assert.are.equal before.size after.size)
              (assert.are_not.equal before.fingerprint after.fingerprint)))
          (h.rmtree tmp))))))

(describe "fen.util.checksum.module-path"
  (fn []
    (after_each
      (fn []
        (h.restore-getenv!)))

    (it "finds Fennel source through the dev-path .fnl analogue of package.path"
      (fn []
        (with-package-path
          "./packages/util/tests/fixtures/checksum/?.lua"
          (fn []
            (assert.are.equal
              "./packages/util/tests/fixtures/checksum/sample/mod.fnl"
              (checksum.module-path :sample.mod))))))

    (it "finds flat first-party extension Fennel sources from the extension-root environment"
      (fn []
        (let [tmp (h.make-tmpdir)
              dir (.. tmp "/adapters/presenters/tui")]
          (h.write-file (.. dir "/manifest.fnl") "{:name :tui}\n")
          (h.write-file (.. dir "/panels/transcript.fnl") "{}\n")
          (h.stub-getenv!
            (fn [name orig]
              (if (= name :FEN_FIRST_PARTY_EXTENSIONS_PATH) tmp
                  (orig name))))
          (assert.are.equal (.. dir "/panels/transcript.fnl")
                            (checksum.module-path :fen.extensions.tui.panels.transcript))
          (h.rmtree tmp))))))
