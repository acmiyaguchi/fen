;; #612: a refresh in flight writes credentials back after logout.
;; Spec: spec/auth (w612RefreshResurrectsAfterLogoutTest).
;; A coroutine runs the real get-fresh-creds! against a temp auth.json and
;; suspends inside the stubbed refresh POST; the real logout! runs on the
;; same path; then the refresh resumes and completes. No network, no real
;; credentials.
(local h (require :fen.testing))
(local {: known-bug} h)
(local json (require :fen.util.json))

(local oauth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local storage-name :fen.extensions.provider_openai.openai_codex_keychain)
(local http-name :fen.util.http)
(local login-name :fen.extensions.provider_openai.openai_codex_login)

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

(describe "#612 refresh vs logout"
          (fn []
            (var saved nil)
            (var tmp nil)
            (var responder nil)
            (var real-write nil)
            (before_each (fn []
                           (set saved {})
                           (each [_ name (ipairs [oauth-name
                                                  login-name
                                                  http-name])]
                             (tset saved name (. package.loaded name)))
                           (set tmp (h.make-tmpdir))
                           (h.stub-log-fallback! (fn [_]))
                           (set real-write io.write)
                           (tset package.loaded http-name
                                 {:request (fn [opts] (responder opts))})
                           (tset package.loaded oauth-name nil)
                           (tset package.loaded login-name nil)))
            (after_each (fn []
                          (set io.write real-write)
                          (each [_ name (ipairs [oauth-name
                                                 login-name
                                                 http-name])]
                            (tset package.loaded name (. saved name)))
                          (h.restore-log-fallback!)
                          (when tmp (h.rmtree tmp))))
            (it "the record removed by logout reappears when the refresh finishes"
                (fn []
                  (known-bug 612
                             (fn []
                               (let [oauth (require oauth-name)
                                     login (require login-name)
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
                                 (set responder
                                      (fn [opts]
                                        (opts.yield)
                                        (srv.handle opts.body)))
                                 (let [a (coroutine.create #(oauth.get-fresh-creds! auth-path
                                                                                    {:yield coroutine.yield}))]
                                   (coroutine.resume a)
                                   ;; logout! reports on stdout; keep the test output clean
                                   (set io.write (fn [& _]))
                                   (let [removed? (login.logout! auth-path)
                                         _ (set io.write real-write)
                                         after-logout (storage.get :openai-codex
                                                                   auth-path)
                                         (a-ok) (coroutine.resume a)
                                         after-refresh (storage.get :openai-codex
                                                                    auth-path)]
                                     (and removed? (= nil after-logout) a-ok
                                          (not= nil after-refresh)
                                          (= after-refresh.refresh "R1")))))))))))
