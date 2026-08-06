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
        (h.restore-discover-enumeration!)))

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
          (set log-sink.fallback (fn [line] (table.insert lines line)))
          (assert.is_true (log.set-level! :debug))
          (log.info "host fallback")
          (set log-sink.fallback nil)
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
