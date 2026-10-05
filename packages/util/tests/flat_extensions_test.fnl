(local h (require :fen.testing))

(fn make-tree []
  (let [root (h.make-tmpdir)]
    (h.write-file (.. root "/alpha/manifest.fnl") "{:name :alpha}\n")
    (h.write-file (.. root "/alpha/init.fnl") "{}\n")
    (h.write-file (.. root "/group/beta/manifest.fnl") "{:name :beta}\n")
    root))

;; flat_extensions is loaded once by the test helper and the launcher; load a
;; fresh copy with lfs hidden so the shell fallback runs, then restore.
(fn with-shell-fallback [stubs thunk]
  (let [names [:lfs :fen.util.flat_extensions :fen.util.process]
        snapshot (h.package-loaded-snapshot names)
        original-popen io.popen]
    (tset package.loaded :lfs {})
    (tset package.loaded :fen.util.flat_extensions nil)
    (each [name value (pairs stubs)]
      (tset package.loaded name value))
    (set io.popen (fn [_] (error "unexpected io.popen")))
    (let [(ok? result) (pcall #(thunk (require :fen.util.flat_extensions)))]
      (set io.popen original-popen)
      (h.restore-package-loaded! snapshot)
      (if ok? result (error result 0)))))

(describe "util.flat_extensions shell fallback"
          (fn []
            (var root nil)
            (before_each (fn [] (set root (make-tree))))
            (after_each (fn [] (when root (h.rmtree root)) (set root nil)))
            (it "enumerates manifests through the fen.util.process seam"
                (fn []
                  (local calls [])
                  (let [map (with-shell-fallback {:fen.util.process {:run-captured (fn [opts]
                                                                                     (table.insert calls
                                                                                                   opts)
                                                                                     ;; find exits nonzero when one subdir is unreadable;
                                                                                     ;; the paths it did print still count.
                                                                                     {:exit-code 1
                                                                                      :output (.. root
                                                                                                  "/alpha/manifest.fnl\n"
                                                                                                  root
                                                                                                  "/group/beta/manifest.fnl\n")})}}
                              (fn [flat] (flat.build-map [root])))]
                    (assert.are.equal 1 (length calls))
                    (assert.is_truthy (string.find (. calls 1 :cmd) "find " 1
                                                   true))
                    (assert.are.equal (.. root "/alpha") map.alpha)
                    (assert.are.equal (.. root "/group/beta") map.beta))))
            (it "finds real manifests with the default process backend"
                (fn []
                  (let [map (with-shell-fallback {}
                              (fn [flat] (flat.build-map [root])))]
                    (assert.are.equal (.. root "/alpha") map.alpha)
                    (assert.are.equal (.. root "/group/beta") map.beta))))))
