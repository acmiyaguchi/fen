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
