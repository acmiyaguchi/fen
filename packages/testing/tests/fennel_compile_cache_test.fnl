(local h (require :fen.testing))
(local cache (require :scripts.test.fennel_compile_cache))

(fn make-fake-fennel [macro-path]
  (let [state {:compile-count 0}
        fake {}]
    (tset fake :version "test-fennel")
    (tset fake :path macro-path)
    (tset fake :macro-path macro-path)
    (let [real-fennel (require :fennel)]
      (tset fake :parser real-fennel.parser)
      (tset fake :string-stream real-fennel.string-stream)
      (tset fake :list? (. real-fennel :list?)))
    (tset fake :searchModule
          (fn [modname path]
            (var found nil)
            (let [rel (string.gsub (tostring modname) "%." "/")]
              (each [pat (string.gmatch (or path "") "([^;]+)")]
                (when (and (not found) (not= pat ""))
                  (let [candidate (string.gsub pat "%?" rel)
                        f (io.open candidate :r)]
                    (when f
                      (f:close)
                      (set found candidate))))))
            found))
    (tset fake :compile-string
          (fn [src _opts]
            (tset state :compile-count (+ state.compile-count 1))
            (let [value (or (string.match src "value%s+(%d+)") "0")]
              (if (string.find src "runtime-error" 1 true)
                  "error('boom from cached chunk')"
                  (string.format "return {value = %s, marker = {}}" value)))))
    (tset fake :load-code
          (fn [lua-source _env chunkname]
            (load lua-source chunkname)))
    (tset fake :dofile
          (fn [filename opts]
            (let [f (assert (io.open filename :r))
                  src (f:read "*a")]
              (f:close)
              (let [lua-source (fake.compile-string src opts)
                    loader (assert (fake.load-code lua-source nil (.. "@" filename)))]
                (loader)))))
    (values fake state)))

(describe "fennel compile cache"
  (fn []
    (var tmp nil)

    (before_each
      (fn []
        (set tmp (h.make-tmpdir))))

    (after_each
      (fn []
        (when tmp
          (h.rmtree tmp)
          (set tmp nil))))

    (it "caches generated Lua but still executes the module each time"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl") "value 1\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))
              installed (cache.install fake {:cache_dir cache-dir :force true})]
          (let [first (fake.dofile source {})
                second (fake.dofile source {})]
            (assert.are.equal 1 state.compile-count)
            (assert.are.equal 1 first.value)
            (assert.are.equal 1 second.value)
            (assert.are.equal 1 installed.stats.misses)
            (assert.are.equal 1 installed.stats.writes)
            (assert.are.equal 1 installed.stats.hits)
            (assert.are_not.equal first.marker second.marker)))))

    (it "invalidates cached Lua when the source file changes"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl") "value 1\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (cache.install fake {:cache_dir cache-dir :force true})
          (assert.are.equal 1 (. (fake.dofile source {}) :value))
          (h.write-file source "value 2\n")
          (assert.are.equal 2 (. (fake.dofile source {}) :value))
          (assert.are.equal 2 state.compile-count))))

    (it "invalidates cached Lua when a direct macro dependency changes"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl")
                                   "(import-macros macros :macros.fixture)\nvalue 1\n")
              macro-dir (.. tmp "/macros")
              macro-source (h.write-file (.. macro-dir "/fixture.fnl")
                                         "{:expand (fn [] `(require :runtime.only))}\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (cache.install fake {:cache_dir cache-dir :force true})
          (fake.dofile source {})
          (fake.dofile source {})
          (assert.are.equal 1 state.compile-count)
          (h.write-file macro-source "{:expand (fn [] `(do (require :runtime.only)))}\n")
          (fake.dofile source {})
          (assert.are.equal 2 state.compile-count))))

    (it "invalidates cached Lua when a transitive macro dependency changes"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl")
                                   "(require-macros :macros.fixture)\nvalue 1\n")
              macro-dir (.. tmp "/macros")
              _fixture (h.write-file (.. macro-dir "/fixture.fnl")
                                     "(require-macros :macros.leaf)\n{}\n")
              leaf (h.write-file (.. macro-dir "/leaf.fnl") "{}\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (cache.install fake {:cache_dir cache-dir :force true})
          (fake.dofile source {})
          (fake.dofile source {})
          (assert.are.equal 1 state.compile-count)
          (h.write-file leaf "{:changed true}\n")
          (fake.dofile source {})
          (assert.are.equal 2 state.compile-count))))

    (it "invalidates cached Lua when a macro module require target changes"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl")
                                   "(require-macros :macros.fixture)\nvalue 1\n")
              macro-dir (.. tmp "/macros")
              _fixture (h.write-file (.. macro-dir "/fixture.fnl")
                                     "(local helper (require :macros.helper))\n{:expand (fn [] helper.value)}\n")
              helper (h.write-file (.. macro-dir "/helper.fnl") "{:value 1}\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (cache.install fake {:cache_dir cache-dir :force true})
          (fake.dofile source {})
          (fake.dofile source {})
          (assert.are.equal 1 state.compile-count)
          (h.write-file helper "{:value 2}\n")
          (fake.dofile source {})
          (assert.are.equal 2 state.compile-count))))

    (it "falls back for dynamic require-macros forms"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl")
                                   "(require-macros (.. prefix :macros))\nvalue 1\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (cache.install fake {:cache_dir cache-dir :force true})
          (fake.dofile source {})
          (fake.dofile source {})
          (assert.are.equal 2 state.compile-count))))

    (it "bypasses eval-compiler forms"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl")
                                   "(eval-compiler (print :compile-time))\nvalue 1\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))
              installed (cache.install fake {:cache_dir cache-dir :force true})]
          (fake.dofile source {})
          (fake.dofile source {})
          (assert.are.equal 2 state.compile-count)
          (assert.are.equal 2 installed.stats.bypasses)
          (assert.are.equal 0 installed.stats.writes))))

    (it "invalidates cached Lua when an include target changes"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl")
                                   "(include :embedded)\nvalue 1\n")
              embedded (h.write-file (.. tmp "/embedded.fnl") "{:value 1}\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (cache.install fake {:cache_dir cache-dir :force true})
          (fake.dofile source {})
          (fake.dofile source {})
          (assert.are.equal 1 state.compile-count)
          (h.write-file embedded "{:value 2}\n")
          (fake.dofile source {})
          (assert.are.equal 2 state.compile-count))))

    (it "invalidates require targets when requireAsInclude is enabled"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl")
                                   "(require :embedded)\nvalue 1\n")
              embedded (h.write-file (.. tmp "/embedded.fnl") "{:value 1}\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (cache.install fake {:cache_dir cache-dir :force true})
          (fake.dofile source {:requireAsInclude true})
          (fake.dofile source {:requireAsInclude true})
          (assert.are.equal 1 state.compile-count)
          (h.write-file embedded "{:value 2}\n")
          (fake.dofile source {:requireAsInclude true})
          (assert.are.equal 2 state.compile-count))))

    (it "does not publish cache entries after failed writes"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl") "value 1\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))
              installed (cache.install fake {:cache_dir cache-dir :force true})
              original-open io.open]
          (set io.open
               (fn [path mode]
                 (let [f (original-open path mode)]
                   (if (and f (= mode :wb) (string.find path ".tmp." 1 true))
                       {:write (fn [_self _data]
                                 (values nil "simulated write failure"))
                        :close (fn [_self] (f:close))}
                       f))))
          (let [(ok? err) (pcall (fn []
                                   (fake.dofile source {})
                                   (fake.dofile source {})))]
            (set io.open original-open)
            (when (not ok?) (error err)))
          (assert.are.equal 2 state.compile-count)
          (assert.are.equal 0 installed.stats.hits)
          (assert.are.equal 0 installed.stats.writes)
          (assert.are.equal 2 installed.stats.errors)
          (let [pipe (assert (io.popen (.. "find " (h.shellquote cache-dir)
                                            " -type f -print") :r))
                files (pipe:read :*a)]
            (pipe:close)
            (assert.are.equal "" files)))))

    (it "changes keys for Fennel versions and Lua targets"
      (fn []
        (let [(first-fennel _state) (make-fake-fennel (.. tmp "/?.fnl"))
              (second-fennel _state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (tset second-fennel :version "next-fennel")
          (assert.are_not.equal
            (cache.make_key first-fennel "module.fnl" {:lua-target "5.4"} "value 1\n")
            (cache.make_key second-fennel "module.fnl" {:lua-target "5.3"} "value 1\n")))))

    (it "fingerprints table options deterministically"
      (fn []
        (let [(fake _state) (make-fake-fennel (.. tmp "/?.fnl"))
              src "value 1\n"
              first (cache.make_key fake "module.fnl"
                                    {:allowedGlobals {:print true :assert true}}
                                    src)
              second (cache.make_key fake "module.fnl"
                                     {:allowedGlobals {:assert true :print true}}
                                     src)]
          (assert.are.equal first second))))

    (it "bypasses unknown compile options"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl") "value 1\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (let [installed (cache.install fake {:cache_dir cache-dir :force true})]
            (fake.dofile source {:future-compiler-option true})
            (fake.dofile source {:future-compiler-option true})
            (assert.are.equal 2 state.compile-count)
            (assert.are.equal 2 installed.stats.bypasses)))))

    (it "bypasses non-serializable compile options"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl") "value 1\n")
              cache-dir (.. tmp "/cache")
              (fake state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (let [installed (cache.install fake {:cache_dir cache-dir :force true})]
            (fake.dofile source {:allowedGlobals {:predicate (fn [] true)}})
            (assert.are.equal 1 state.compile-count)
            (assert.are.equal 1 installed.stats.bypasses)))))

    (it "loads cached chunks with the original Fennel filename in tracebacks"
      (fn []
        (let [source (h.write-file (.. tmp "/module.fnl") "runtime-error\n")
              cache-dir (.. tmp "/cache")
              (fake _state) (make-fake-fennel (.. tmp "/?.fnl"))]
          (cache.install fake {:cache_dir cache-dir :force true})
          (let [(ok? err) (pcall fake.dofile source {})]
            (assert.is_false ok?)
            (assert.is_truthy (string.find (tostring err) source 1 true))))))))
