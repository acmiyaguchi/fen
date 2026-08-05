;; Tests for the extension-discovery enumeration seam (issue #475).
;;
;; Two properties matter: a host can inject its own enumeration backend to
;; supply the discovered-manifest list with no filesystem or subprocess access,
;; and the default POSIX enumeration is unchanged for the CLI.

(local h (require :fen.testing))

(fn spec-names [specs]
  (let [out []]
    (each [_ s (ipairs specs)]
      (table.insert out s.name))
    out))

(describe "fen.core.extensions.loader.discover"
  (fn []
    (describe "injected enumeration backend"
      (fn []
        ;; A backend that errors on every filesystem/env probe. If discovery
        ;; touches the disk while an enumeration backend is injected, these
        ;; blow up, proving the injected backend is the only enumeration path.
        (local exploding-vfs
          {:getenv (fn [] (error "getenv touched"))
           :stat (fn [] (error "stat touched"))
           :list-dir (fn [] (error "list-dir touched"))
           :pwd-physical (fn [] (error "pwd-physical touched"))})

        (var enumerate-calls 0)

        (after_each
          (fn []
            (h.restore-discover-enumeration!)
            (h.restore-path-vfs!)))

        (it "supplies manifests with no filesystem access"
          (fn []
            (set enumerate-calls 0)
            (h.stub-path-vfs! exploding-vfs)
            (h.stub-discover-enumeration!
              {:enumerate
               (fn [explicit-paths ?yield-fn]
                 (set enumerate-calls (+ enumerate-calls 1))
                 [{:name :alpha :dir "host:alpha" :source :first-party
                   :first-party? true :manifest {:name :alpha}}
                  {:name :beta :dir "host:beta" :source :user
                   :first-party? false :manifest {:name :beta}}])})
            (let [discover (require :fen.core.extensions.loader.discover)
                  specs (discover.discover [])]
              (assert.are.equal 1 enumerate-calls)
              (assert.are.same [:alpha :beta] (spec-names specs))
              ;; Downstream shape is preserved: dedupe annotates version data.
              (assert.are.equal 1 (. specs 1 :version-count))
              (assert.are.equal :host:alpha (. specs 1 :dir)))))

        (it "dedupes host-supplied specs by name, first wins"
          (fn []
            (h.stub-discover-enumeration!
              {:enumerate
               (fn []
                 [{:name :dup :dir "host:primary" :source :explicit
                   :explicit? true :manifest {}}
                  {:name :dup :dir "host:shadowed" :source :user
                   :manifest {}}])})
            (let [discover (require :fen.core.extensions.loader.discover)
                  specs (discover.discover [])]
              (assert.are.equal 1 (length specs))
              (assert.are.equal :host:primary (. specs 1 :dir))
              (assert.are.equal 2 (. specs 1 :version-count))
              (assert.is_true (. specs 1 :versions 1 :active?))
              (assert.is_false (. specs 1 :versions 2 :active?)))))

        (it "passes explicit-paths and yield-fn through to the backend"
          (fn []
            (var seen-paths nil)
            (var seen-yield nil)
            (h.stub-discover-enumeration!
              {:enumerate
               (fn [explicit-paths ?yield-fn]
                 (set seen-paths explicit-paths)
                 (set seen-yield ?yield-fn)
                 [])})
            (let [discover (require :fen.core.extensions.loader.discover)
                  yield (fn [])
                  specs (discover.discover ["/a" "/b"] yield)]
              (assert.are.same ["/a" "/b"] seen-paths)
              (assert.are.equal yield seen-yield)
              (assert.are.equal 0 (length specs)))))))

    (describe "default POSIX enumeration"
      (fn []
        (var tmp nil)

        (before_each
          (fn []
            (set tmp (h.make-tmpdir))
            ;; Neutralize env-driven roots so this test only sees what it writes.
            (h.stub-getenv!
              (fn [name orig]
                (if (= name :XDG_CONFIG_HOME) (.. tmp "/xdg")
                    (= name :FEN_EXTENSIONS_PATH) nil
                    (= name :FEN_FIRST_PARTY_EXTENSIONS_PATH) nil
                    (orig name))))
            ;; Force a fresh default backend + frontend for each case.
            (h.restore-discover-enumeration!)))

        (after_each
          (fn []
            (h.restore-getenv!)
            (h.restore-discover-enumeration!)
            (when tmp (h.rmtree tmp))))

        (it "discovers an explicit manifest directory from disk"
          (fn []
            (let [dir (.. tmp "/myext")]
              (h.write-file (.. dir "/manifest.lua")
                            "return { name = 'myext' }\n")
              (h.write-file (.. dir "/init.lua")
                            "return function(api) end\n")
              (let [discover (require :fen.core.extensions.loader.discover)
                    specs (discover.discover [dir])
                    by-name {}]
                (each [_ s (ipairs specs)]
                  (tset by-name s.name s))
                (let [spec (. by-name :myext)]
                  (assert.is_not_nil spec)
                  (assert.are.equal :explicit spec.source)
                  (assert.is_true spec.explicit?)
                  (assert.are.equal dir spec.dir))))))

        (it "discovers a single-file extension from an explicit path"
          (fn []
            (let [file (h.write-file (.. tmp "/solo.lua")
                                     "return function(api) end\n")
                  discover (require :fen.core.extensions.loader.discover)
                  specs (discover.discover [file])
                  by-name {}]
              (each [_ s (ipairs specs)]
                (tset by-name s.name s))
              (let [spec (. by-name :solo)]
                (assert.is_not_nil spec)
                (assert.are.equal :explicit spec.source)
                (assert.are.equal file spec.entry-path)))))

        (it "still returns embedded first-party specs with no external roots"
          (fn []
            (let [discover (require :fen.core.extensions.loader.discover)
                  specs (discover.discover [])
                  by-name {}]
              (each [_ s (ipairs specs)]
                (tset by-name s.name s))
              ;; Embedded first-party manifests are required, not walked, so
              ;; they appear even when no filesystem root yields anything.
              (assert.is_not_nil (. by-name :builtin_tools))
              (assert.is_true (. by-name :builtin_tools :first-party?)))))))))
