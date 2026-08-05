(local helpers (require :fen.testing))

(describe "util.http"
  (fn []
    (after_each (fn [] (helpers.restore-http!)))

    (it "dispatches to the backend with the caller's opts table"
      (fn []
        (let [seen []]
          (helpers.stub-http!
            (fn [opts]
              (table.insert seen opts)
              {:status 200 :body "ok"}))
          (let [http (require :fen.util.http)
                resp (http.request {:method :POST
                                    :url "https://example.test/x"
                                    :headers {:content-type "application/json"}
                                    :body "{\"a\":1}"})]
            (assert.are.equal 1 (length seen))
            (assert.are.equal "POST" (. seen 1 :method))
            (assert.are.equal "https://example.test/x" (. seen 1 :url))
            (assert.are.equal "{\"a\":1}" (. seen 1 :body))
            (assert.are.equal 200 resp.status)
            (assert.are.equal "ok" resp.body)
            (assert.is_nil resp.error)))))

    (it "returns the backend's error shape unchanged"
      (fn []
        (helpers.stub-http!
          (fn [_opts] {:error "connection refused"}))
        (let [http (require :fen.util.http)
              resp (http.request {:method :GET :url "https://nope.test"})]
          (assert.are.equal "connection refused" resp.error)
          (assert.is_nil resp.status)
          (assert.is_nil resp.body))))

    (it "passes through on-chunk and yield without inspecting them"
      (fn []
        (let [captured {}]
          (helpers.stub-http!
            (fn [opts]
              (set captured.on-chunk opts.on-chunk)
              (set captured.yield opts.yield)
              {:status 200 :body ""}))
          (let [http (require :fen.util.http)
                on-chunk (fn [_] nil)
                yield (fn [] nil)
                _ (http.request {:method :POST :url "https://x.test"
                                 : on-chunk : yield})]
            (assert.are.equal on-chunk captured.on-chunk)
            (assert.are.equal yield captured.yield)))))

    (it "applies timeout defaults for a bare request"
      (fn []
        (let [seen []]
          (helpers.stub-http!
            (fn [opts]
              (table.insert seen opts)
              {:status 200 :body "ok"}))
          (let [http (require :fen.util.http)]
            (http.request {:method :GET :url "https://example.test/x"})
            (assert.are.equal 600000 (. seen 1 :timeout-ms))
            (assert.are.equal 30000 (. seen 1 :connect-timeout-ms))
            (assert.are.equal 60000 (. seen 1 :idle-timeout-ms))))))

    (it "preserves a caller-supplied idle-timeout-ms of 0"
      (fn []
        (let [seen []]
          (helpers.stub-http!
            (fn [opts]
              (table.insert seen opts)
              {:status 200 :body "ok"}))
          (let [http (require :fen.util.http)]
            (http.request {:method :GET :url "https://example.test/x"
                           :idle-timeout-ms 0})
            (assert.are.equal 0 (. seen 1 :idle-timeout-ms))))))

    (it "passes through caller-supplied non-zero timeouts unchanged"
      (fn []
        (let [seen []]
          (helpers.stub-http!
            (fn [opts]
              (table.insert seen opts)
              {:status 200 :body "ok"}))
          (let [http (require :fen.util.http)]
            (http.request {:method :GET :url "https://example.test/x"
                           :timeout-ms 1000
                           :connect-timeout-ms 2000
                           :idle-timeout-ms 3000})
            (assert.are.equal 1000 (. seen 1 :timeout-ms))
            (assert.are.equal 2000 (. seen 1 :connect-timeout-ms))
            (assert.are.equal 3000 (. seen 1 :idle-timeout-ms))))))

    (it "does not mutate the caller's opts table"
      (fn []
        (helpers.stub-http! (fn [_opts] {:status 200 :body "ok"}))
        (let [http (require :fen.util.http)
              opts {:method :GET :url "https://example.test/x"}]
          (http.request opts)
          (assert.is_nil opts.timeout-ms)
          (assert.is_nil opts.connect-timeout-ms)
          (assert.is_nil opts.idle-timeout-ms))))

    (it "preserves accumulate-body? false across the defensive copy"
      (fn []
        (let [seen []]
          (helpers.stub-http!
            (fn [opts]
              (table.insert seen opts)
              {:status 200 :body "ok"}))
          (let [http (require :fen.util.http)]
            (http.request {:method :GET :url "https://example.test/x"
                           :accumulate-body? false})
            (assert.are.equal false (. seen 1 :accumulate-body?))))))

    ;; Pin the Fennel timeout defaults to the fen_http.c fallback literals so the
    ;; two duplicated copies cannot silently drift (#469). The applied-default
    ;; tests above pin the Fennel side; this reads the vendored C fallbacks.
    (it "keeps fen_http.c fallback literals in sync with the Fennel defaults"
      (fn []
        (let [f (assert (io.open "packages/util/vendor/fen_http.c" :r)
                        "cannot open packages/util/vendor/fen_http.c")
              src (f:read :*a)]
          (f:close)
          (let [(_ _ timeout) (src:find "\"timeout_ms\",%s*(%d+)")
                (_ _ connect) (src:find "\"connect_timeout_ms\",%s*(%d+)")
                (_ _ idle) (src:find "\"idle_timeout_ms\",%s*(%d+)")]
            (assert.are.equal "600000" timeout)
            (assert.are.equal "30000" connect)
            (assert.are.equal "60000" idle)))))

    (it "fails fast with a canonical error for a non-blocking backend and no yield"
      (fn []
        (let [calls []]
          ;; Backend declares it cannot block; caller passes no :yield.
          (tset package.loaded :fen.util.http.backend
                {:request (fn [opts] (table.insert calls opts)
                            {:status 200 :body "ok"})
                 :capabilities {:blocking? false}})
          (tset package.loaded :fen.util.http nil)
          (let [http (require :fen.util.http)
                resp (http.request {:method :GET :url "https://x.test"})]
            ;; Fails before dispatch: the backend is never called.
            (assert.are.equal 0 (length calls))
            (assert.are.equal "blocking" resp.capability)
            (assert.is_string resp.error)
            (assert.is_nil resp.status)
            (assert.is_nil resp.body)
            (assert.is_nil resp.curl-code)))))

    (it "drives a non-blocking backend when the caller supplies yield"
      (fn []
        (let [calls []]
          (tset package.loaded :fen.util.http.backend
                {:request (fn [opts] (table.insert calls opts)
                            {:status 200 :body "ok"})
                 :capabilities {:blocking? false}})
          (tset package.loaded :fen.util.http nil)
          (let [http (require :fen.util.http)
                yield (fn [] nil)
                resp (http.request {:method :GET :url "https://x.test"
                                    : yield})]
            (assert.are.equal 1 (length calls))
            (assert.are.equal yield (. calls 1 :yield))
            (assert.are.equal 200 resp.status)
            (assert.are.equal "ok" resp.body)
            (assert.is_nil resp.capability)))))

    (it "allows blocking for a default backend that declares no capabilities"
      (fn []
        (let [calls []]
          ;; Mirrors the fen_http.so default: absent capabilities => blocking ok.
          (helpers.stub-http!
            (fn [opts] (table.insert calls opts) {:status 200 :body "ok"}))
          (let [http (require :fen.util.http)
                resp (http.request {:method :GET :url "https://x.test"})]
            (assert.are.equal 1 (length calls))
            (assert.are.equal 200 resp.status)
            (assert.is_nil resp.capability)))))

    (it "declares blocking support on the native backend"
      (fn []
        (let [old-native (. package.loaded :fen.util.http.backends.native)]
          (tset package.loaded :fen.util.http.backends.native nil)
          (let [native (require :fen.util.http.backends.native)]
            (tset package.loaded :fen.util.http.backends.native old-native)
            (assert.are.equal true (. native :capabilities :blocking?))))))

    (it "translates native curl_code errors to kebab-case curl-code"
      (fn []
        (let [old-fen-http (. package.loaded :fen_http)
              old-native (. package.loaded :fen.util.http.backends.native)]
          (tset package.loaded :fen_http
                {:request (fn [_opts]
                            {:error "Server returned nothing" :curl_code 52})})
          (tset package.loaded :fen.util.http.backends.native nil)
          (let [native (require :fen.util.http.backends.native)
                resp (native.request {:method :GET :url "https://x.test"})]
            (tset package.loaded :fen_http old-fen-http)
            (tset package.loaded :fen.util.http.backends.native old-native)
            (assert.are.equal "Server returned nothing" resp.error)
            (assert.are.equal 52 resp.curl-code)
            (assert.is_nil resp.curl_code)))))))
