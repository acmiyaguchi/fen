;; Account quota is upstream data, not conversation token accounting.
(local json (require :fen.util.json))
(local http (require :fen.util.http))
(local auth (require :fen.extensions.provider_openai.openai_codex_oauth))
(local state (require :fen.extensions.provider_openai.usage_state))
(local storage (require :fen.extensions.provider_openai.openai_codex_keychain))
(local path (require :fen.util.path))
(local sha256 (require :fen.util.sha256))
(local coroutines (require :fen.util.coroutines))
(local lfs (require :lfs))
(local clock (require :fen.util.clock))
(local mutex (require :fen.util.file_mutex))
(local M {})

(fn number? [n]
  (and (= (type n) :number) (= n n) (< (math.abs n) math.huge)))

(local array-mt (getmetatable (json.decode "[]")))

(fn object? [value]
  (and (= (type value) :table) (not= (getmetatable value) array-mt)))

(fn present? [value]
  (and (not= value nil) (not (json.null? value))))

(fn M.parse [body]
  (let [windows []]
    (var malformed? (not (object? body)))
    (when (object? body)
      (each [_ group (ipairs [:rate_limit :code_review_rate_limit])]
        (let [rate (. body group)]
          (when (present? rate)
            (if (not (object? rate))
                (set malformed? true)
                (each [_ name (ipairs [:primary_window :secondary_window])]
                  (let [w (. rate name)]
                    (when (present? w)
                      (if (and (object? w) (number? w.used_percent)
                               (<= 0 w.used_percent 100)
                               (number? w.limit_window_seconds)
                               (> w.limit_window_seconds 0) (number? w.reset_at)
                               (> w.reset_at 0))
                          (table.insert windows
                                        {:name (.. group "/" name)
                                         :used-percent w.used_percent
                                         :remaining-percent (- 100
                                                               w.used_percent)
                                         :length-seconds w.limit_window_seconds
                                         :reset-at w.reset_at})
                          (set malformed? true))))))))))
    ;; A malformed supported shape is an API failure, not absent support.
    (if malformed? (values [] :api)
        (= (length windows) 0) (values windows :unsupported)
        (values windows nil))))

;; Disk cache is deliberately independent of auth storage and contains no secrets.
(fn M.cache-path []
  (or state.cache-path (.. (path.state-dir :fen) "/codex-usage.json")))

(fn account-key []
  (let [(ok creds) (pcall storage.get :openai-codex)]
    (when (and ok (= (type (?. creds :accountId)) :string))
      (sha256.hex-digest creds.accountId))))

(fn clear-cache []
  (set state.windows [])
  (set state.retrieved-at nil)
  (set state.attempted-at nil)
  (set state.failure :unavailable)
  (set state.loaded? false))

(fn M.load-cache [key]
  (when (not= key state.account-key)
    (clear-cache)
    (set state.account-key key))
  (when (and key (not= state.cache-path false))
    (let [f (io.open (M.cache-path) :r)]
      (when f
        (let [text (f:read "*a")]
          (f:close)
          (let [(ok data) (pcall json.decode text)]
            (when (and ok (object? data) (= data.version 1)
                       (= data.account-key key) (object? data.snapshot))
              (let [s data.snapshot
                    windows []]
                (var valid?
                     (and (= (type s.windows) :table)
                          (or (not (present? s.retrieved-at))
                              (number? s.retrieved-at))
                          (or (not (present? s.attempted-at))
                              (number? s.attempted-at))))
                (when valid?
                  (each [_ w (ipairs s.windows)]
                    (if (and (object? w) (= (type w.name) :string)
                             (number? w.used-percent) (<= 0 w.used-percent 100)
                             (number? w.remaining-percent)
                             (= w.remaining-percent (- 100 w.used-percent))
                             (number? w.length-seconds) (> w.length-seconds 0)
                             (number? w.reset-at) (> w.reset-at 0))
                        (table.insert windows
                                      {:name w.name
                                       :used-percent w.used-percent
                                       :remaining-percent w.remaining-percent
                                       :length-seconds w.length-seconds
                                       :reset-at w.reset-at})
                        (set valid? false))))
                (when (and valid?
                           (or (= (length windows) 0) (number? s.retrieved-at))
                           (or (not state.attempted-at)
                               (and (number? s.attempted-at)
                                    (> s.attempted-at state.attempted-at))))
                  (set state.windows windows)
                  (set state.retrieved-at
                       (when (number? s.retrieved-at) s.retrieved-at))
                  (set state.attempted-at
                       (when (number? s.attempted-at) s.attempted-at))
                  (set state.failure
                       (when (or (= s.failure :auth) (= s.failure :network)
                                 (= s.failure :api) (= s.failure :unsupported)
                                 (= s.failure :unavailable))
                         s.failure))
                  (set state.loaded? true))))))))))

(fn M.save-cache []
  (when (and state.account-key (not= state.cache-path false))
    (let [file (M.cache-path)
          tmp (os.tmpname)]
      ;; Use a unique sibling so rename is atomic even across filesystems.
      (os.remove tmp)
      (let [temp (.. file "." (path.basename tmp))]
        (path.ensure-dir! (path.dirname file))
        (let [f (io.open temp :w)]
          (when f
            (let [(ok written) (pcall #(f:write (json.encode {:version 1
                                                              :account-key state.account-key
                                                              :snapshot (M.snapshot)})))]
              (local closed (f:close))
              (local renamed (and ok written closed (os.rename temp file)))
              (os.remove temp)
              renamed)))))))

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
                 (if (or state.loaded? state.failure reset?
                         (>= (- now state.retrieved-at) 60))
                     :stale
                     :fresh)
                 (if (= state.failure :unsupported) :unsupported :unavailable))}))

;; The stable lock inode must never be renamed/deleted: fcntl locks attach to
;; the inode, whereas the cache itself is replaced atomically. Kernel release
;; on process exit avoids stale lock ownership after a crash. The local mutex
;; also serializes coroutines (fcntl locks alone are process-owned).
(fn claim-attempt [?yield]
  (fn claim []
    (M.load-cache (account-key))
    (let [now (os.time)]
      (when (or (not state.attempted-at) (>= (- now state.attempted-at) 60))
        (set state.attempted-at now)
        (if (= state.cache-path false)
            true
            (M.save-cache)))))

  (if (= state.cache-path false)
      (claim)
      (let [file (M.cache-path)]
        (path.ensure-dir! (path.dirname file))
        (mutex.with-file (.. file ".lock")
          ?yield
          (fn []
            (let [f (io.open (.. file ".lock") :a)]
              ;; Fail closed: no HTTP unless the shared attempt was persisted.
              (when f
                (let [(ok result) (pcall (fn []
                                           (local deadline
                                                  (+ (clock.monotonic-ms) 1000))
                                           (var locked? (lfs.lock f :w))
                                           (while (and (not locked?)
                                                       (< (clock.monotonic-ms)
                                                          deadline))
                                             (if ?yield (?yield)
                                                 (clock.sleep-ms 10))
                                             (set locked? (lfs.lock f :w)))
                                           (when locked? (claim))))]
                  ;; close releases the kernel lock on success, failure, or cancellation.
                  (f:close)
                  (if ok result (error result 0))))))))))

(fn M.refresh [?yield]
  (when (claim-attempt ?yield)
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
                      (windows failure) (if decoded (M.parse body)
                                            (values [] :api))]
                  (if failure
                      (set state.failure failure)
                      (do
                        (set state.windows windows)
                        (set state.retrieved-at (os.time))
                        (set state.failure nil)
                        (set state.loaded? false))))))))
    (M.save-cache))
  (M.snapshot))

(fn M.label [w]
  (let [hours (/ w.length-seconds 3600)]
    (if (and (< hours 24) (= hours (math.floor hours)))
        (.. (tostring (math.floor hours)) "h")
        (and (>= hours 24) (= (% hours 24) 0))
        (.. (tostring (math.floor (/ hours 24))) "d")
        w.name)))

(fn M.remaining [w now]
  (if (>= now w.reset-at) 100 w.remaining-percent))

(fn M.style [remaining stale?]
  (if (< remaining 10) :error
      (< remaining 25) :tool
      stale? :dim
      :status))

(fn M.status [snapshot width now]
  (when (and (not= snapshot.status :unsupported)
             (not= snapshot.failure :unsupported)
             (> (length snapshot.windows) 0))
    (let [parts []
          stale? (= snapshot.status :stale)]
      (var least nil)
      (var minimum 100)
      (each [_ w (ipairs snapshot.windows)]
        (let [remaining (M.remaining w now)
              text (.. (M.label w) ":" (string.format "%.0f%%" remaining))]
          (table.insert parts text)
          (when (or (not least) (< remaining minimum))
            (set minimum remaining)
            (set least text))))
      (let [prefix (if stale? "~" "")
            all (.. prefix (table.concat parts " "))
            text (if (>= width 65) all
                    (.. prefix least))]
        {:text (string.sub text 1 (math.max 0 width))
         :style (M.style minimum stale?)}))))

(fn M.relative [seconds]
  (let [minutes (math.max 0 (math.floor (/ seconds 60)))]
    (if (>= minutes 1440) (.. (tostring (math.floor (/ minutes 1440))) "d")
        (>= minutes 60) (.. (tostring (math.floor (/ minutes 60))) "h"
                           (if (> (% minutes 60) 0)
                               (.. (tostring (% minutes 60)) "m")
                               ""))
        (.. (tostring minutes) "m"))))

(fn M.rows [snapshot width now]
  (let [stale? (= snapshot.status :stale)
        rows [{:text (.. "codex quota"
                         (if snapshot.retrieved-at
                             (.. " - " (if stale? "stale, " "") "updated "
                                 (if (< (- now snapshot.retrieved-at) 60)
                                     (.. (tostring (math.max 0
                                                             (- now
                                                                snapshot.retrieved-at)))
                                         "s")
                                     (M.relative (- now snapshot.retrieved-at)))
                                 " ago")
                             "")
                         (if snapshot.failure (.. " / " snapshot.failure) ""))
               :style (if stale? :dim :assistant)}]]
    (if (or (= snapshot.status :unsupported) (= snapshot.failure :unsupported)
            (= snapshot.failure :auth) (= (length snapshot.windows) 0))
        (table.insert rows {:text (if (or (= snapshot.status :unsupported)
                                          (= snapshot.failure :unsupported))
                                      "Quota unavailable: unsupported by this account."
                                      (= snapshot.failure :auth)
                                      "Quota unavailable: sign in to openai-codex."
                                      (.. "Quota unavailable: "
                                          (or snapshot.failure :unavailable) "."))
                            :style :dim})
        (each [_ w (ipairs snapshot.windows)]
          (let [remaining (M.remaining w now)
                bar-width (math.max 1 (math.min 20 (- width 32)))
                filled (math.floor (* bar-width (/ remaining 100)))]
            (table.insert rows
                          {:text (.. (M.label w) " [" (string.rep "#" filled)
                                     (string.rep "-" (- bar-width filled)) "] "
                                     (string.format "%.0f%% left" remaining)
                                     " / "
                                     (if (>= now w.reset-at) "reset"
                                         (.. "resets "
                                             (M.relative (- w.reset-at now)))))
                           :style (M.style remaining stale?)}))))
    (each [_ row (ipairs rows)]
      (set row.text (string.sub row.text 1 (math.max 0 width))))
    rows))

(fn active-codex? [ctx]
  (var provider (?. ctx :status-info :provider))
  (when (and ctx.state (not= ctx.state.active-workspace-id :main-session))
    (each [_ workspace (ipairs (or ctx.state.workspaces []))]
      (when (= workspace.id ctx.state.active-workspace-id)
        (set provider workspace.provider))))
  (= provider :openai-codex))

(fn panel-snapshot []
  (if state.panel-unsupported?
      {:windows [] :status :unsupported :failure :unsupported}
      (M.snapshot)))

(fn M.register [api]
  (M.load-cache (account-key))
  (api.register :status
                {:name :codex-quota
                 :side :left
                 :order 21
                 :render (fn [ctx]
                           (when (active-codex? ctx)
                             ;; Reserve space for model/context and right-side identity.
                             (M.status (M.snapshot) (math.max 0 (- ctx.w 35))
                                       (os.time))))})
  (api.register :panel {:name :codex-quota
                        :placement :below-status
                        :order 20
                        :height (fn [ctx]
                                  (if state.visible?
                                      (length (M.rows (panel-snapshot) ctx.w
                                                      (os.time)))
                                      0))
                        :render (fn [ctx]
                                  (if state.visible?
                                      (M.rows (panel-snapshot) ctx.w (os.time))
                                      []))})
  (api.register :command
                {:name :usage
                 :description "Toggle Codex account quota; demand refresh at most once per minute."
                 :idle-only? false
                 :handler (fn [_args ctx]
                            (set state.visible? (not state.visible?))
                            (set state.panel-unsupported?
                                 (not= (?. ctx :opts :provider) :openai-codex))
                            (when (and state.visible? (not state.refresh-co))
                              (when (not state.panel-unsupported?)
                                (set state.refresh-co
                                     (coroutines.create #(M.refresh coroutine.yield))))
                              (api.emit {:type :redraw})))})
  (api.on :runtime-tick
          (fn [_]
            (when state.refresh-co
              (let [co state.refresh-co]
                (coroutine.resume co)
                (when (= (coroutine.status co) :dead)
                  (set state.refresh-co nil)
                  (api.emit {:type :redraw}))))))
  (api.on :dismiss (fn [_]
                     (when state.visible?
                       (set state.visible? false)
                       (api.emit {:type :redraw}))))
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
