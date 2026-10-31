;; Codex OAuth refresh as one critical section under the auth lock (fixed in #605):
;; - #611: concurrent refreshers serialize; the second one re-reads auth.json
;;   inside the lock and uses the winner's tokens instead of reusing R0.
;; - #612: logout waits for an in-flight refresh, and the write-back is a
;;   compare-and-rename that never resurrects a removed record or clobbers
;;   a newer login written outside the lock.
;; - #613: a cancel raised during the refresh POST is honoured only after the
;;   rotated tokens are persisted.
;; Spec: spec/auth and spec/auth/proofs/rotation (reach...Test witnesses).
;; Coroutines stand in for processes: each runs the real get-fresh-creds!
;; against one temp auth.json and suspends inside the stubbed refresh POST.
;; The fake token endpoint rotates Rk -> R(k+1) and rejects a reused token.
;; No network, no real credentials.
(local h (require :fen.testing))
(local json (require :fen.util.json))

(local oauth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local storage-name :fen.extensions.provider_openai.openai_codex_keychain)
(local login-name :fen.extensions.provider_openai.openai_codex_login)
(local http-name :fen.util.http)

(local FAKE-JWT (.. "header."
                    "eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjX3Rlc3QifX0"
                    ".signature"))

(fn make-server [?valid]
  "Fake token endpoint with single-use refresh-token rotation."
  (let [srv {:valid (or ?valid "R0") :n 0 :posts 0}]
    (fn srv.handle [body]
      (set srv.posts (+ srv.posts 1))
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

(fn expired-record [refresh]
  {:type :oauth :access FAKE-JWT : refresh :expires 0 :accountId "acc_test"})

(fn login-record [refresh]
  {:type :oauth
   :access FAKE-JWT
   : refresh
   :expires (* (+ (os.time) 3600) 1000)
   :accountId "acc_test"})

(fn resume! [co]
  (let [(ok? value) (coroutine.resume co)]
    (assert.is_true ok? (tostring value))
    value))

(describe "Codex refresh under the auth lock"
          (fn []
            (var saved nil)
            (var tmp nil)
            (var responder nil)
            (var real-write nil)
            (var oauth nil)
            (var storage nil)
            (var auth-path nil)
            (before_each (fn []
                           (set saved {})
                           (each [_ name (ipairs [oauth-name
                                                  login-name
                                                  http-name])]
                             (tset saved name (. package.loaded name)))
                           (set tmp (h.make-tmpdir))
                           (set auth-path (.. tmp "/auth.json"))
                           (h.stub-log-fallback! (fn [_]))
                           (set real-write io.write)
                           (tset package.loaded http-name
                                 {:request (fn [opts] (responder opts))})
                           (tset package.loaded oauth-name nil)
                           (tset package.loaded login-name nil)
                           (set oauth (require oauth-name))
                           (set storage (require storage-name))))
            (after_each (fn []
                          (set io.write real-write)
                          (each [_ name (ipairs [oauth-name
                                                 login-name
                                                 http-name])]
                            (tset package.loaded name (. saved name)))
                          (h.restore-log-fallback!)
                          (when tmp (h.rmtree tmp))))

            (fn suspend-before-commit [srv]
              ;; the POST suspends before the server processes it
              (set responder
                   (fn [opts]
                     (opts.yield)
                     (srv.handle opts.body))))

            (fn refresher []
              (coroutine.create #(oauth.get-fresh-creds! auth-path
                                                         {:yield coroutine.yield})))

            (it "#611: a second refresher waits and uses the winner's tokens"
                (fn []
                  (let [srv (make-server)]
                    (storage.set :openai-codex (expired-record "R0") auth-path)
                    (suspend-before-commit srv)
                    (let [a (refresher)
                          b (refresher)]
                      (resume! a)
                      ;; b waits on the lock instead of POSTing R0 again
                      (resume! b)
                      (let [a-creds (resume! a)
                            b-creds (resume! b)]
                        (assert.equal :dead (coroutine.status a))
                        (assert.equal :dead (coroutine.status b))
                        (assert.equal "R1" a-creds.refresh)
                        (assert.equal "R1" b-creds.refresh)
                        (assert.equal 1 srv.posts)
                        (assert.equal "R1"
                                      (. (storage.get :openai-codex auth-path)
                                         :refresh)))))))
            (it "#611: a rejected refresh re-reads auth.json and uses a valid record written meanwhile"
                (fn []
                  ;; R0's rotation was lost; the server only knows R5
                  (let [srv (make-server "R5")]
                    (storage.set :openai-codex (expired-record "R0") auth-path)
                    (suspend-before-commit srv)
                    (let [a (refresher)]
                      (resume! a)
                      ;; a login written by a writer outside the lock
                      (storage.save {:openai-codex (login-record "L0")}
                                    auth-path)
                      (let [creds (resume! a)]
                        (assert.equal "L0" creds.refresh)
                        (assert.equal "L0"
                                      (. (storage.get :openai-codex auth-path)
                                         :refresh)))))))
            (it "#612: logout waits for the in-flight refresh and its removal sticks"
                (fn []
                  (let [srv (make-server)
                        login (require login-name)]
                    (storage.set :openai-codex (expired-record "R0") auth-path)
                    (suspend-before-commit srv)
                    (set io.write (fn [& _]))
                    (let [a (refresher)
                          out (coroutine.create #(login.logout! auth-path
                                                                coroutine.yield))]
                      (resume! a)
                      (resume! out)
                      (assert.equal :suspended (coroutine.status out))
                      (assert.equal "R1" (. (resume! a) :refresh))
                      (assert.is_true (resume! out))
                      (set io.write real-write)
                      (assert.is_nil (storage.get :openai-codex auth-path))))))
            (it "#612: a refresh never resurrects a record removed outside the lock"
                (fn []
                  (let [srv (make-server)]
                    (storage.set :openai-codex (expired-record "R0") auth-path)
                    (storage.set :other {:keep "this"} auth-path)
                    (suspend-before-commit srv)
                    (let [a (refresher)]
                      (resume! a)
                      (storage.save {:other {:keep "this"}} auth-path)
                      (let [(ok? err) (coroutine.resume a)]
                        (assert.is_false ok?)
                        (assert.truthy (string.find (tostring err)
                                                    "No Codex credentials" 1
                                                    true)))
                      (assert.is_nil (storage.get :openai-codex auth-path))
                      (assert.equal "this"
                                    (. (storage.get :other auth-path) :keep))))))
            (it "#612: a refresh of the old account never clobbers a newer login"
                (fn []
                  (let [srv (make-server)]
                    (storage.set :openai-codex (expired-record "R0") auth-path)
                    (suspend-before-commit srv)
                    (let [a (refresher)]
                      (resume! a)
                      (storage.save {:openai-codex (login-record "L0")}
                                    auth-path)
                      (assert.equal "L0" (. (resume! a) :refresh))
                      (assert.equal "L0"
                                    (. (storage.get :openai-codex auth-path)
                                       :refresh))))))
            (it "#613: a cancel after the server committed persists the rotation, then propagates"
                (fn []
                  (let [srv (make-server)
                        marker {:type :cancel}]
                    (storage.set :openai-codex (expired-record "R0") auth-path)
                    ;; the server commits first, then the wait for the response yields
                    (set responder
                         (fn [opts]
                           (let [resp (srv.handle opts.body)]
                             (when opts.yield (opts.yield))
                             resp)))
                    (let [(ok? err) (pcall oauth.get-fresh-creds! auth-path
                                           {:yield (fn [] (error marker))})]
                      (assert.is_false ok?)
                      (assert.equal marker err))
                    (assert.equal "R1"
                                  (. (storage.get :openai-codex auth-path)
                                     :refresh))
                    (assert.equal "R1" srv.valid)
                    ;; the persisted R1 is usable: no further POST, no re-login
                    (let [creds (oauth.get-fresh-creds! auth-path)]
                      (assert.equal "R1" creds.refresh)
                      (assert.equal 1 srv.posts)))))))
