;; Account quota is upstream data, not conversation token accounting.
(local json (require :fen.util.json))
(local http (require :fen.util.http))
(local auth (require :fen.extensions.provider_openai.openai_codex_oauth))
(local state (require :fen.extensions.provider_openai.usage_state))
(local M {})

(fn number? [n]
  (and (= (type n) :number) (= n n) (< (math.abs n) math.huge)))

(fn M.parse [body]
  (let [windows []]
    (when (= (type body) :table)
      (each [_ group (ipairs [:rate_limit :code_review_rate_limit])]
        (let [rate (. body group)]
          (when (= (type rate) :table)
            (each [_ name (ipairs [:primary_window :secondary_window])]
              (let [w (. rate name)]
                (when (and (= (type w) :table) (number? w.used_percent)
                           (<= 0 w.used_percent 100)
                           (number? w.limit_window_seconds)
                           (> w.limit_window_seconds 0) (number? w.reset_at)
                           (> w.reset_at 0))
                  (table.insert windows
                                {:name (.. group "/" name)
                                 :used-percent w.used_percent
                                 :remaining-percent (- 100 w.used_percent)
                                 :length-seconds w.limit_window_seconds
                                 :reset-at w.reset_at}))))))))
    windows))

(fn M.snapshot []
  (let [now (os.time)
        windows (icollect [_ w (ipairs state.windows)]
                  (collect [k v (pairs w)] k v))]
    ;; Freshness must also expire at a window reset, even inside the TTL.
    (var reset? false)
    (each [_ w (ipairs windows)] (when (>= now w.reset-at) (set reset? true)))
    {:provider :openai-codex
     :scope :account-quota
     :windows windows
     :retrieved-at state.retrieved-at
     :attempted-at state.attempted-at
     :failure state.failure
     :status (if (> (length windows) 0)
                 (if (or state.failure reset?
                         (>= (- now state.retrieved-at) 60))
                     :stale
                     :fresh)
                 (if (= state.failure :unsupported) :unsupported :unavailable))}))

(fn M.refresh [?yield]
  (let [now (os.time)]
    (when (or (not state.attempted-at) (>= (- now state.attempted-at) 60))
      (set state.attempted-at now)
      ;; Preserve cancellation identity, but never surface auth/HTTP exception text.
      (var cancelled nil)
      (local yield-fn (when ?yield
                        (fn []
                          (let [(ok value) (pcall ?yield)]
                            (when (not ok) (set cancelled value)
                              (error value 0))))))
      (let [(ok creds) (pcall auth.get-fresh-creds! nil {:yield yield-fn})]
        (when cancelled (error cancelled 0))
        (if (not ok)
            (set state.failure :auth)
            (let [(ok resp) (pcall http.request
                                   {:method :GET
                                    :url "https://chatgpt.com/backend-api/wham/usage"
                                    :headers {:authorization (.. "Bearer "
                                                                 creds.access)
                                              :chatgpt-account-id creds.accountId
                                              :accept "application/json"}
                                    :timeout-ms 10000
                                    :connect-timeout-ms 5000
                                    :yield yield-fn})]
              (when cancelled (error cancelled 0))
              (if (or (not ok) resp.error)
                  (set state.failure :network)
                  (or (= resp.status 401) (= resp.status 403))
                  (set state.failure :auth)
                  (or (= resp.status 404) (= resp.status 405))
                  (set state.failure :unsupported)
                  (not= resp.status 200)
                  (set state.failure :api)
                  (let [(decoded body) (pcall json.decode (or resp.body ""))
                        windows (if decoded (M.parse body) [])]
                    (if (> (length windows) 0)
                        (do
                          (set state.windows windows)
                          (set state.retrieved-at (os.time))
                          (set state.failure nil))
                        (set state.failure (if decoded :unsupported :api))))))))))
  (M.snapshot))

(fn M.register [api]
  (api.register :tool
                {:name :account_usage
                 :label "account usage"
                 :exposure :search
                 :description "Inspect Codex account-wide quota percentages and reset times (not context capacity or conversation tokens). Demand refresh, at most once per minute; failures retain stale data."
                 :parameters {:type :object :properties {}}
                 :execute (fn [_args _ctx ?yield]
                            {:content [{:type :text
                                        :text (json.encode (M.refresh ?yield))}]})})
  (api.register :introspect
                {:name :account-usage
                 :description "Cached sanitized account quota; no network or auth access."
                 :snapshot (fn [_ctx] (M.snapshot))}))

M
