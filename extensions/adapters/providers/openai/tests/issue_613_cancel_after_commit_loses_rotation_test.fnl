;; #613: cancelling during the refresh POST loses the rotation and forces a
;; re-login. Spec: spec/auth (w613CancelAfterCommitLosesRotationTest).
;; The fake token endpoint commits R0 -> R1, then the stubbed transport calls
;; the caller's cooperative yield (as fen.util.http does while it waits for
;; the response), which raises a cancel. No network, no real credentials.
(local h (require :fen.testing))
(local {: known-bug} h)
(local json (require :fen.util.json))

(local oauth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local storage-name :fen.extensions.provider_openai.openai_codex_keychain)
(local http-name :fen.util.http)

(local FAKE-JWT (.. "header."
                    "eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjX3Rlc3QifX0"
                    ".signature"))

(fn make-server []
  "Fake token endpoint with single-use refresh-token rotation."
  (let [srv {:valid "R0" :n 0}]
    (fn srv.handle [body]
      (let [rt (string.match body "refresh_token=([^&]+)")]
        (if (= rt srv.valid)
            (do
              (set srv.n (+ srv.n 1))
              (set srv.valid (.. "R" srv.n))
              {:status 200
               :body (json.encode {:access_token FAKE-JWT
                                   :refresh_token srv.valid
                                   :expires_in 3600})})
            {:status 400
             :body "{\"error\":\"invalid_grant\",\"error_description\":\"refresh_token_reused\"}"})))

    srv))

(describe "#613 cancel during the refresh POST"
          (fn []
            (var saved nil)
            (var tmp nil)
            (var responder nil)
            (before_each (fn []
                           (set saved {})
                           (each [_ name (ipairs [oauth-name http-name])]
                             (tset saved name (. package.loaded name)))
                           (set tmp (h.make-tmpdir))
                           (h.stub-log-fallback! (fn [_]))
                           (tset package.loaded http-name
                                 {:request (fn [opts] (responder opts))})
                           (tset package.loaded oauth-name nil)))
            (after_each (fn []
                          (each [_ name (ipairs [oauth-name http-name])]
                            (tset package.loaded name (. saved name)))
                          (h.restore-log-fallback!)
                          (when tmp (h.rmtree tmp))))
            (it "auth.json keeps the revoked R0 and the next refresh is rejected"
                (fn []
                  (known-bug 613
                             (fn []
                               (let [oauth (require oauth-name)
                                     storage (require storage-name)
                                     auth-path (.. tmp "/auth.json")
                                     srv (make-server)]
                                 (storage.set :openai-codex
                                              {:type :oauth
                                               :access FAKE-JWT
                                               :refresh "R0"
                                               :expires 0
                                               :accountId "acc_test"}
                                              auth-path)
                                 ;; the server commits first, then the wait for the response yields
                                 (set responder
                                      (fn [opts]
                                        (let [resp (srv.handle opts.body)]
                                          (when opts.yield (opts.yield))
                                          resp)))
                                 (let [(cancel-ok cancel-err) (pcall oauth.get-fresh-creds!
                                                                     auth-path
                                                                     {:yield (fn []
                                                                               (error :cancelled
                                                                                      0))})
                                       stored (storage.get :openai-codex
                                                           auth-path)
                                       (next-ok next-err) (pcall oauth.get-fresh-creds!
                                                                 auth-path)]
                                   (and (not cancel-ok)
                                        (= cancel-err :cancelled)
                                        (= stored.refresh "R0")
                                        (= srv.valid "R1") (not next-ok)
                                        (not= nil
                                              (string.find (tostring next-err)
                                                           "invalid_grant" 1
                                                           true)))))))))))
