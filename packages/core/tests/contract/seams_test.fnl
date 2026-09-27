;; External-host contracts for injectable embedding seams. These deliberately
;; exercise only public APIs after package.loaded backend injection.
(local h (require :fen.testing))

(describe "embedding seam contracts"
  (fn []
    (after_each
      (fn []
        (h.restore-http!)
        (h.restore-path-vfs!)
        (h.restore-clock!)
        (h.restore-process!)
        (h.restore-random!)
        (h.restore-checksum!)
        (h.restore-storage!)
        (h.restore-discover-enumeration!)
        (h.restore-log-fallback!)))

    (it "preserves host backend request, VFS, clock, process, random, and checksum shapes"
      (fn []
        (local calls {:http [] :getenv [] :stat [] :list-dir [] :pwd []
                      :sleep [] :setenv [] :random [] :checksum []})
        (h.stub-http!
          (fn [opts]
            (table.insert calls.http opts)
            (when opts.on-chunk (opts.on-chunk "chunk"))
            (when opts.yield (opts.yield))
            {:status 201 :body "chunk" :headers {:x-host "yes"}}))
        (h.stub-path-vfs!
          {:getenv (fn [name] (table.insert calls.getenv name)
                     (if (= name :HOME) "/host" nil))
           :stat (fn [path] (table.insert calls.stat path)
                   (if (= path "/host/file") :file :directory))
           :list-dir (fn [path] (table.insert calls.list-dir path) ["entry"])
           :pwd-physical (fn [path] (table.insert calls.pwd path) "/physical")})
        (h.stub-clock! {:monotonic-ms (fn [] 42)
                        :sleep-ms (fn [ms] (table.insert calls.sleep ms))})
        (h.stub-process!
          {:setenv (fn [name value]
                     (table.insert calls.setenv [name value])
                     (values true nil nil))})
        (h.stub-random! {:bytes (fn [n] (table.insert calls.random n) "xyz")})
        (h.stub-checksum!
          {:file-fingerprint (fn [p] (table.insert calls.checksum p) {:fingerprint "f"})
           :module-path (fn [_] nil)
           :module-fingerprint (fn [_] {:fingerprint "etag"})})
        (let [http (require :fen.util.http)
              path (require :fen.util.path)
              clock (require :fen.util.clock)
              process (require :fen.util.process)
              random (require :fen.util.random)
              checksum (require :fen.util.checksum)
              chunks []
              yielded {:n 0}
              response (http.request {:method :POST :url "host://request"
                                      :body "payload"
                                      :on-chunk (fn [s] (table.insert chunks s))
                                      :yield (fn [] (set yielded.n (+ yielded.n 1)))})]
          (assert.are.equal 201 response.status)
          (assert.are.equal "chunk" response.body)
          (assert.are.same ["chunk"] chunks)
          (assert.are.equal 1 yielded.n)
          (assert.are.equal "host://request" (. calls.http 1 :url))
          (assert.are.equal "/host" (path.home))
          (assert.is_true (path.file-exists? "/host/file"))
          (assert.is_true (path.dir-exists? "/host/dir"))
          (assert.are.same ["entry"] (path.list-dir "/host"))
          (assert.are.equal "/physical" (path.pwd-physical "."))
          (assert.are.equal 42 (clock.monotonic-ms))
          (clock.sleep-ms 7)
          (process.setenv! :HOST_VALUE "set")
          (assert.are.equal "xyz" (random.bytes 3))
          (assert.are.equal "etag" (. (checksum.module-fingerprint :host.module) :fingerprint))
          (assert.are.same [7] calls.sleep)
          (assert.are.same [[:HOST_VALUE "set"]] calls.setenv)
          (assert.are.same [3] calls.random))))

    (it "uses injected storage, discovery, and log fallback without host files"
      (fn []
        (local store {})
        (local enumerated {:n 0})
        (local lines [])
        (h.stub-storage! {:read (fn [path] (. store path))
                          :write! (fn [path bytes] (tset store path bytes))})
        (h.stub-discover-enumeration!
          {:enumerate (fn [explicit-paths yield-fn]
                        (set enumerated.n (+ enumerated.n 1))
                        (when yield-fn (yield-fn))
                        [{:name :host-extension :dir "host:extension"
                          :source :host :manifest {:name :host-extension}}])})
        (let [storage (require :fen.core.storage)
              discover (require :fen.core.extensions.loader.discover)
              log-sink (require :fen.util.log_sink)
              log (require :fen.util.log)]
          (storage.write! "host://settings.json" "{\"theme\":\"dark\"}")
          (assert.are.equal "{\"theme\":\"dark\"}" (storage.read "host://settings.json"))
          (let [specs (discover.discover [] (fn [] nil))]
            (assert.are.equal 1 enumerated.n)
            (assert.are.equal :host-extension (. specs 1 :name)))
          (set log-sink.level nil)
          (h.stub-log-fallback! (fn [line] (table.insert lines line)))
          (assert.is_true (log.set-level! :debug))
          (log.info "host fallback")
          (h.restore-log-fallback!)
          (assert.are.equal 1 (length lines))
          (assert.is_truthy (string.find (. lines 1) "host fallback" 1 true))
          (set log-sink.level nil))))

    (it "excludes backend selector modules from the core reload set"
      (fn []
        ;; Backend selectors are host injection points (pre-populated in
        ;; package.loaded); reloading one in place would clobber the injected
        ;; backend with the on-disk default mid-session.
        (require :fen.util.path)
        (require :fen.util.random)
        (let [reload (require :fen.core.extensions.loader.reload)
              mods (reload.core-modules)]
          (assert.is_table (. package.loaded "fen.util.path.backend"))
          (assert.is_table (. package.loaded "fen.util.random.backend"))
          (each [_ m (ipairs mods)]
            (assert.is_nil (string.find m "%.backend$")
                           (.. m " must not be core-reloadable"))))))

    (it "keeps injected backends in effect across a forced core reload"
      (fn []
        ;; Load the reload machinery (and what it captures) before injecting,
        ;; so only the seam frontends below see the host backends.
        (let [reload (require :fen.core.extensions.loader.reload)
              state (require :fen.core.extensions.state)
              _models (require :fen.core.llm.models)
              original-core-modules reload.core-modules
              original-fingerprints state.reload-fingerprints
              original-failures state.reload-core-failures
              http-calls []
              http-backend {:request (fn [opts] (table.insert http-calls opts)
                                       {:status 204 :body ""})}
              vfs {:getenv (fn [name] (if (= name :HOME) "/host" nil))}
              clock-backend {:monotonic-ms (fn [] 42) :sleep-ms (fn [_] nil)}
              random-backend {:bytes (fn [n] (string.rep "h" n))}
              seams [:fen.util.clock :fen.util.http :fen.util.path :fen.util.random]]
          (h.stub-path-vfs! vfs)
          (h.stub-http! http-backend.request)
          (h.stub-clock! clock-backend)
          (h.stub-random! random-backend)
          (let [http (require :fen.util.http)
                path (require :fen.util.path)
                clock (require :fen.util.clock)
                random (require :fen.util.random)
                injected-http (. package.loaded :fen.util.http.backend)
                ;; Watch both each frontend and its selector in the real set.
                wanted (collect [_ m (ipairs seams)] m true)
                _ (each [_ m (ipairs seams)] (tset wanted (.. m ".backend") true))
                reload-set (icollect [_ m (ipairs (reload.core-modules))]
                             (when (. wanted m) m))]
            ;; The real reload set holds the frontends but never the selectors.
            (assert.are.same seams reload-set)
            (set reload.core-modules (fn [] reload-set))
            (let [(ok? n failures)
                  (pcall reload.reload-core! nil {:force? true})]
              (set reload.core-modules original-core-modules)
              (set state.reload-fingerprints original-fingerprints)
              (set state.reload-core-failures original-failures)
              (assert.is_true ok? (tostring n))
              (assert.are.same [] failures)
              (assert.are.equal (length seams) n))
            ;; Same frontend tables, rebuilt in place, still bound to the host.
            (assert.are.equal http (. package.loaded :fen.util.http))
            (assert.are.equal injected-http (. package.loaded :fen.util.http.backend))
            (assert.are.equal vfs (. package.loaded :fen.util.path.backend))
            (assert.are.equal 204 (. (http.request {:url "host://after-reload"}) :status))
            (assert.are.equal "host://after-reload" (. http-calls 1 :url))
            (assert.are.equal "/host" (path.home))
            (assert.are.equal 42 (clock.monotonic-ms))
            (assert.are.equal "hh" (random.bytes 2))))))

    (it "fails fast for a cooperative-only HTTP backend without yield"
      (fn []
        (local dispatched {:n 0})
        (tset package.loaded :fen.util.http.backend
              {:capabilities {:blocking? false}
               :request (fn [_] (set dispatched.n (+ dispatched.n 1)) {})})
        (tset package.loaded :fen.util.http nil)
        (let [http (require :fen.util.http)
              response (http.request {:url "host://request"})]
          (assert.are.equal "blocking" response.capability)
          (assert.are.equal 0 dispatched.n))))))
