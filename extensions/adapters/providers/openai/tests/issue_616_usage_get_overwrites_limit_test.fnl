;; #616: a usage GET in flight overwrites a usage_limit_reached recorded
;; meanwhile and reports the older data as fresh.
;; Spec: spec/auth (w616GetOverwrites429Test) and spec/auth/proofs/quota.
;; The real M.refresh runs in a coroutine and suspends inside the stubbed
;; GET (server data: 97% used); record-limit records a 429; then the GET
;; completes. Cache in a temp dir; auth and storage are stubbed.
(local h (require :fen.testing))
(local {: known-bug} h)
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
            (it "the 429 is overwritten by the in-flight GET's data, marked fresh"
                (fn []
                  (known-bug 616
                             (fn []
                               (let [usage (require module)
                                     co (coroutine.create #(usage.refresh coroutine.yield))]
                                 (coroutine.resume co)
                                 (usage.record-limit {:length-seconds 18000
                                                      :reset-at (+ (os.time)
                                                                   600)}
                                                     "acct")
                                 (let [after-429 (usage.snapshot)
                                       r429 (least-remaining usage after-429)
                                       (ok?) (coroutine.resume co)
                                       after-get (usage.snapshot)
                                       rget (least-remaining usage after-get)]
                                   (and ok? (= r429 0)
                                        (= :dead (coroutine.status co))
                                        (= rget 3) (= after-get.status :fresh))))))))))
