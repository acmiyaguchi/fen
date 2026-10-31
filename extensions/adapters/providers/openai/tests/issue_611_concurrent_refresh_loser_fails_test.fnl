;; #611: two processes refresh concurrently; the loser fails although valid
;; credentials are on disk. Spec: spec/auth (w611ConcurrentRefreshLoserFailsTest).
;; Two coroutines stand in for the two processes: each runs the real
;; get-fresh-creds! against one temp auth.json and suspends inside the
;; stubbed refresh POST. The fake token endpoint rotates Rk -> R(k+1) and
;; rejects a reused token. No network, no real credentials.
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

(describe "#611 concurrent Codex refresh"
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
            (it "the second refresher fails with invalid_grant while auth.json holds the valid R1"
                (fn []
                  (known-bug 611
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
                                 ;; the POST suspends before the server processes it
                                 (set responder
                                      (fn [opts]
                                        (opts.yield)
                                        (srv.handle opts.body)))
                                 (let [run #(oauth.get-fresh-creds! auth-path
                                                                    {:yield coroutine.yield})
                                       a (coroutine.create run)
                                       b (coroutine.create run)]
                                   (coroutine.resume a)
                                   (coroutine.resume b)
                                   (let [(a-ok a-creds) (coroutine.resume a)
                                         (b-ok b-err) (coroutine.resume b)
                                         stored (storage.get :openai-codex
                                                             auth-path)]
                                     (and a-ok (= a-creds.refresh "R1")
                                          (not b-ok)
                                          (not= nil
                                                (string.find (tostring b-err)
                                                             "refresh HTTP 400"
                                                             1 true))
                                          (= stored.refresh "R1")
                                          (= srv.valid "R1")))))))))))
