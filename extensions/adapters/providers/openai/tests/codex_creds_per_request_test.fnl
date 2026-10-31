;; Codex requests resolve credentials per request (#614, fixed in #605): an
;; expiring record passed through provider-options.creds (as main.fnl ->
;; interactive.fnl do) is never pinned; the request re-reads auth.json via
;; get-fresh-creds!, which refreshes it, instead of sending the stale token.
;; Spec: spec/auth (reachExpiryRefreshThenRequestTest) and
;; spec/auth/proofs/pinning.
;; get-fresh-creds! is stubbed to return a new token and HTTP is stubbed to
;; accept only that token. No network, no real credentials.
(local responses-name :fen.extensions.provider_openai.openai_codex_responses)
(local oauth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local http-name :fen.util.http)

(describe "Codex credentials per request"
          (fn []
            (var saved nil)
            (var sent nil)
            (var fresh-calls 0)
            (var fresh-yield nil)
            (before_each (fn []
                           (set saved {})
                           (each [_ name (ipairs [responses-name
                                                  oauth-name
                                                  http-name])]
                             (tset saved name (. package.loaded name)))
                           (set sent nil)
                           (set fresh-calls 0)
                           (set fresh-yield nil)
                           (tset package.loaded http-name
                                 {:request (fn [opts]
                                             (set sent
                                                  opts.headers.authorization)
                                             (if (or (= sent "Bearer NEW")
                                                     (= sent "Bearer STATIC"))
                                                 {:status 200
                                                  :headers {}
                                                  :body "{\"models\":[]}"}
                                                 {:status 401
                                                  :headers {}
                                                  :body "expired"}))})
                           (tset package.loaded oauth-name
                                 {:get-fresh-creds! (fn [_ opts]
                                                      (set fresh-calls
                                                           (+ fresh-calls 1))
                                                      (set fresh-yield
                                                           (?. opts :yield))
                                                      {:access "NEW"
                                                       :accountId "acc"
                                                       :expires (* (+ (os.time)
                                                                      3600)
                                                                   1000)})})
                           (tset package.loaded responses-name nil)))
            (after_each (fn []
                          (each [_ name (ipairs [responses-name
                                                 oauth-name
                                                 http-name])]
                            (tset package.loaded name (. saved name)))))
            (it "re-resolves an expired record passed at construction and sends the fresh token"
                (fn []
                  (let [codex (require responses-name)
                        yield (fn [])
                        models (codex.list-models {:creds {:type :oauth
                                                           :access "OLD"
                                                           :accountId "acc"
                                                           :expires 0}
                                                   : yield})]
                    (assert.is_table models)
                    (assert.equal "Bearer NEW" sent)
                    (assert.equal 1 fresh-calls)
                    (assert.equal yield fresh-yield))))
            (it "re-resolves even a still-valid stored record on each request"
                (fn []
                  (let [codex (require responses-name)
                        opts {:creds {:type :oauth
                                      :access "OLD"
                                      :accountId "acc"
                                      :expires (* (+ (os.time) 3600) 1000)}}]
                    (codex.list-models opts)
                    (codex.list-models opts)
                    (assert.equal "Bearer NEW" sent)
                    (assert.equal 2 fresh-calls))))
            (it "uses static credentials without an expiry as given"
                (fn []
                  (let [codex (require responses-name)]
                    (codex.list-models {:creds {:access "STATIC"
                                                :accountId "acc"}})
                    (assert.equal "Bearer STATIC" sent)
                    (assert.equal 0 fresh-calls))))))
