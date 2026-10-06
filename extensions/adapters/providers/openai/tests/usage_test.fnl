(local json (require :fen.util.json))
(local module :fen.extensions.provider_openai.usage)
(local state (require :fen.extensions.provider_openai.usage_state))
(local auth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local http-name :fen.util.http)

(describe "account usage"
          (fn []
            (var old-auth nil)
            (var old-http nil)
            (var usage nil)
            (var response nil)
            (var calls 0)
            (var auth-fails false)
            (var seen-yield nil)
            (local window
                   {:used_percent 25
                    :limit_window_seconds 18000
                    :reset_at (+ (os.time) 500)})
            (before_each (fn []
                           (set old-auth (. package.loaded auth-name))
                           (set old-http (. package.loaded http-name))
                           (set state.cache-path false)
                           (set state.account-key nil)
                           (set state.loaded? false)
                           (set state.windows [])
                           (set state.retrieved-at nil)
                           (set state.attempted-at nil)
                           (set state.failure :unavailable)
                           (set calls 0)
                           (set auth-fails false)
                           (set response
                                {:status 200
                                 :body (json.encode {:rate_limit {:primary_window window}
                                                     :account_id "synthetic-private"})})
                           (tset package.loaded auth-name
                                 {:get-fresh-creds! (fn [_path opts]
                                                      (set seen-yield
                                                           opts.yield)
                                                      (when opts.yield
                                                        (opts.yield))
                                                      (when auth-fails
                                                        (error "synthetic-secret"))
                                                      {:access "synthetic"
                                                       :accountId "synthetic"})})
                           (tset package.loaded http-name
                                 {:request (fn [opts]
                                             (assert.equal :GET opts.method)
                                             (assert.equal 10000
                                                           opts.timeout-ms)
                                             (when opts.yield (opts.yield))
                                             (set calls (+ calls 1))
                                             response)})
                           (tset package.loaded module nil)
                           (set usage (require module))))
            (after_each (fn []
                          (tset package.loaded auth-name old-auth)
                          (tset package.loaded http-name old-http)
                          (tset package.loaded module nil)))
            (it "normalizes only validated quota fields"
                (fn []
                  (assert.same [{:name "rate_limit/primary_window"
                                 :used-percent 25
                                 :remaining-percent 75
                                 :length-seconds 18000
                                 :reset-at window.reset_at}]
                               (usage.parse {:rate_limit {:primary_window window}}))
                  (assert.same [] (usage.parse {}))
                  (assert.same []
                               (usage.parse {:rate_limit {:primary_window {:used_percent 101}}}))))
            (it "refreshes on demand and cached introspection never accesses auth/network"
                (fn []
                  (local specs {})
                  (usage.register {:on (fn [_event _handler])
                                   :register (fn [kind spec]
                                               (tset specs kind spec))})
                  (assert.equal :unavailable
                                (?. ((. specs :introspect :snapshot) {})
                                    :status))
                  (local result ((. specs :tool :execute) {} {} (fn [])))
                  (assert.equal :fresh
                                (?. (json.decode (. result.content 1 :text))
                                    :status))
                  (assert.is_function seen-yield)
                  (assert.equal :fresh
                                (?. ((. specs :introspect :snapshot) {})
                                    :status))
                  (usage.refresh)
                  (assert.equal 1 calls)
                  (assert.is_nil (string.find (. result.content 1 :text)
                                              "synthetic"))
                  (tset state.windows 1 :used-percent 99)
                  (local snapshot (usage.snapshot))
                  (tset snapshot.windows 1 :used-percent 0)
                  (assert.equal 99 (. state.windows 1 :used-percent))))
            (it "ages and retains stale windows on network failure"
                (fn []
                  (usage.refresh)
                  (set state.retrieved-at (- (os.time) 61))
                  (assert.equal :stale (?. (usage.snapshot) :status))
                  (set state.attempted-at (- (os.time) 61))
                  (set response {:error "synthetic-secret"})
                  (local out (usage.refresh))
                  (assert.equal :stale out.status)
                  (assert.equal :network out.failure)
                  (assert.equal 1 (length out.windows))))
            (it "classifies auth API malformed and unsupported results without secrets"
                (fn []
                  (each [_ scenario (ipairs [{:status 401 :reason :auth}
                                             {:status 500 :reason :api}
                                             {:status 404 :reason :unsupported}
                                             {:status 200
                                              :body "{}"
                                              :reason :unsupported}
                                             {:status 200
                                              :body "not JSON"
                                              :reason :api}])]
                    (set state.attempted-at nil)
                    (set response scenario)
                    (assert.equal scenario.reason (?. (usage.refresh) :failure)))
                  (set state.attempted-at nil)
                  (set auth-fails true)
                  (assert.equal :auth (?. (usage.refresh) :failure))))
            (it "distinguishes absent quota from malformed supported shapes and retains safe cache"
                (fn []
                  (each [_ body (ipairs ["{}"
                                         "{\"rate_limit\":null}"
                                         "{\"rate_limit\":{\"primary_window\":null}}"
                                         "{\"rate_limit\":{},\"other_quota\":{\"secret\":\"synthetic-private\"}}"])]
                    (set state.attempted-at nil)
                    (set response {:status 200 :body body})
                    (local out (usage.refresh))
                    (assert.equal :unsupported out.failure)
                    (assert.equal :unsupported out.status))
                  (each [_ body (ipairs ["null"
                                         "false"
                                         "[]"
                                         "[{}]"
                                         "\"synthetic-private\""
                                         "{\"rate_limit\":false}"
                                         "{\"code_review_rate_limit\":[]}"
                                         "{\"rate_limit\":{\"primary_window\":{}}}"
                                         "{\"rate_limit\":{\"primary_window\":false}}"
                                         "{\"rate_limit\":{\"primary_window\":[]}}"
                                         "{\"rate_limit\":{\"primary_window\":{\"used_percent\":25,\"limit_window_seconds\":18000}}}"])]
                    (set state.windows [])
                    (set state.attempted-at nil)
                    (set response {:status 200 :body body})
                    (local out (usage.refresh))
                    (assert.equal :api out.failure)
                    (assert.equal :unavailable out.status)
                    (assert.is_nil (string.find (json.encode out) "synthetic"))
                    (set state.windows
                         (usage.parse {:rate_limit {:primary_window window}}))
                    (set state.retrieved-at (os.time))
                    (set state.attempted-at nil)
                    (local cached (usage.refresh))
                    (assert.equal :api cached.failure)
                    (assert.equal :stale cached.status)
                    (assert.equal 25 (. cached.windows 1 :used-percent)))
                  (each [_ field (ipairs [:used_percent
                                          :limit_window_seconds
                                          :reset_at])]
                    (each [_ invalid (ipairs [json.null
                                              "synthetic-secret"
                                              -1
                                              math.huge])]
                      (local bad (collect [k v (pairs window)] k v))
                      (tset bad field invalid)
                      (local (windows failure)
                             (usage.parse {:rate_limit {:primary_window bad}}))
                      (assert.same [] windows)
                      (assert.equal :api failure)))
                  ;; Do not silently claim fresh partial data when another supported window is broken.
                  (local (windows failure)
                         (usage.parse {:rate_limit {:primary_window window}
                                       :code_review_rate_limit {:secondary_window {}}}))
                  (assert.same [] windows)
                  (assert.equal :api failure)))
            (it "expires at reset and propagates cooperative cancellation"
                (fn []
                  (usage.refresh)
                  (tset state.windows 1 :reset-at (- (os.time) 1))
                  (assert.equal :stale (?. (usage.snapshot) :status))
                  (set state.attempted-at nil)
                  (local marker {})
                  (local (ok err) (pcall usage.refresh (fn [] (error marker))))
                  (assert.is_false ok)
                  (assert.equal marker err)))))

(describe "quota OAuth cooperative path"
          (fn []
            (it "passes the demand callback through an expiring OAuth refresh"
                (fn []
                  (var witnessed? false)
                  (let [storage-name :fen.extensions.provider_openai.openai_codex_keychain
                        old-storage (. package.loaded storage-name)
                        old-http (. package.loaded http-name)
                        old-auth (. package.loaded auth-name)
                        callback (fn [])]
                    (tset package.loaded storage-name
                          {:get (fn [_provider _path]
                                  {:type :oauth
                                   :access "synthetic"
                                   :refresh "synthetic"
                                   :expires 0})})
                    (tset package.loaded http-name
                          {:request (fn [opts]
                                      (assert.equal callback opts.yield)
                                      (assert.equal 30000 opts.timeout-ms)
                                      (set witnessed? true)
                                      {:error "synthetic failure"})})
                    (tset package.loaded auth-name nil)
                    (let [auth (require auth-name)
                          (ok _err) (pcall auth.get-fresh-creds! nil
                                           {:yield callback})]
                      (tset package.loaded storage-name old-storage)
                      (tset package.loaded http-name old-http)
                      (tset package.loaded auth-name old-auth)
                      (assert.is_true witnessed?)
                      (assert.is_false ok)))))))
