(local checksum (require :fen.util.checksum))
(local h (require :fen.testing))
(local testing (require :fen.testing))

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

(describe "fen.util.checksum fingerprint-provider seam (#468)"
  (fn []
    (after_each
      (fn []
        (testing.restore-checksum!)))

    (it "consults a host-injected fingerprint provider for module versions"
      (fn []
        (var seen [])
        (testing.stub-checksum!
          {:module-fingerprint (fn [modname]
                                 (table.insert seen modname)
                                 {:fingerprint (.. "etag-" modname)})
           :module-path (fn [_] nil)
           :file-fingerprint (fn [_] nil)})
        (let [cs (testing.reload-module :fen.util.checksum)]
          ;; A module invisible to package.searchpath still gets a version from
          ;; the injected provider, restoring change detection for hosts whose
          ;; modules load through a custom package.searchers entry.
          (let [fp (cs.module-fingerprint :fen.host.only.in.vm)]
            (assert.are.equal "etag-fen.host.only.in.vm" fp.fingerprint))
          (assert.are.same [:fen.host.only.in.vm] seen))))

    (it "uses the default io.open/searchpath backend when not injected"
      (fn []
        (testing.restore-checksum!)
        (let [cs (testing.reload-module :fen.util.checksum)]
          ;; No source file resolves for a bare fake module: the default
          ;; backend returns nil rather than a fabricated version.
          (assert.is_nil (cs.module-fingerprint :fen.zz_missing_module_468))
          ;; And a real on-disk file still fingerprints via io.open.
          (let [tmp (h.make-tmpdir)
                path (.. tmp "/source.fnl")]
            (h.write-file path "abc\n")
            (let [fp (cs.file-fingerprint path)]
              (assert.are.equal 4 fp.size)
              (assert.are.equal "abc\n" fp.fingerprint))
            (h.rmtree tmp)))))))
