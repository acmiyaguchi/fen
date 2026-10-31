;; A usage GET in flight must not overwrite a usage_limit_reached recorded
;; meanwhile (#616, fixed in #605): the GET's result is applied under the
;; cache lock onto the latest record, keeping limits observed after it was sent.
;; Spec: spec/auth (reach616...Test) and spec/auth/proofs/quota.
;; The real M.refresh runs in a coroutine and suspends inside the stubbed
;; GET (server data: 97% used); record-limit records a 429; then the GET
;; completes. Cache in a temp dir; auth and storage are stubbed.
(local h (require :fen.testing))
(local json (require :fen.util.json))

(local module :fen.extensions.provider_openai.usage)
(local state-name :fen.extensions.provider_openai.usage_state)
(local auth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local storage-name :fen.extensions.provider_openai.openai_codex_keychain)
(local http-name :fen.util.http)
(local names [module state-name auth-name storage-name http-name])

(fn least-remaining [usage snapshot]
  (var least nil)
  (each [_ w (ipairs snapshot.windows)]
    (let [r (usage.remaining w (os.time))]
      (when (or (not least) (< r least))
        (set least r))))
  least)

(describe "#616 usage GET vs usage_limit_reached"
          (fn []
            (var saved nil)
            (var tmp nil)
            (before_each (fn []
                           (set saved {})
                           (each [_ name (ipairs names)]
                             (tset saved name (. package.loaded name)))
                           (set tmp (h.make-tmpdir))
                           (tset package.loaded state-name
                                 {:windows []
                                  :failure :unavailable
                                  :cache-path (.. tmp "/codex-usage.json")})
                           (tset package.loaded storage-name
                                 {:get (fn [_] {:accountId "acct"})})
                           (tset package.loaded auth-name
                                 {:get-fresh-creds! (fn [_ _]
                                                      {:accountId "acct"
                                                       :access "tok"})})
                           (tset package.loaded http-name
                                 {:request (fn [opts]
                                             ;; the GET waits for its response
                                             (opts.yield)
                                             {:status 200
                                              :body (json.encode {:rate_limit {:primary_window {:used_percent 97
                                                                                                :limit_window_seconds 18000
                                                                                                :reset_at (+ (os.time)
                                                                                                             600)}}})})})
                           (tset package.loaded module nil)))
            (after_each (fn []
                          (each [_ name (ipairs names)]
                            (tset package.loaded name (. saved name)))
                          (when tmp (h.rmtree tmp))))
            (it "keeps a 429 recorded while the GET was in flight, in memory and on disk"
                (fn []
                  (let [usage (require module)
                        co (coroutine.create #(usage.refresh coroutine.yield))]
                    (coroutine.resume co)
                    (usage.record-limit {:length-seconds 18000
                                         :reset-at (+ (os.time) 600)}
                                        "acct")
                    (assert.equal 0 (least-remaining usage (usage.snapshot)))
                    (let [(ok? err) (coroutine.resume co)]
                      (assert.is_true ok? (tostring err)))
                    (assert.equal :dead (coroutine.status co))
                    (assert.equal 0 (least-remaining usage (usage.snapshot)))
                    ;; a fresh process reading the cache sees the limit too
                    (let [state (require state-name)]
                      (set state.windows [])
                      (set state.account-key nil)
                      (set state.file-sig nil))
                    (assert.equal 0 (least-remaining usage (usage.snapshot))))))
            (it "replaces a limit observed before the GET was sent"
                (fn []
                  (let [usage (require module)
                        state (require state-name)
                        co (coroutine.create #(usage.refresh coroutine.yield))]
                    (set state.windows
                         [{:name "rate_limit/primary_window"
                           :used-percent 100
                           :remaining-percent 0
                           :length-seconds 18000
                           :reset-at (+ (os.time) 600)
                           :limited-at (- (os.time) 120)}])
                    (coroutine.resume co)
                    (let [(ok? err) (coroutine.resume co)]
                      (assert.is_true ok? (tostring err)))
                    (let [snapshot (usage.snapshot)]
                      (assert.equal 3 (least-remaining usage snapshot))
                      (assert.equal :fresh snapshot.status)))))))
