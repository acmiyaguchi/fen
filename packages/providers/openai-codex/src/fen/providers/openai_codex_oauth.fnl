;; OpenAI Codex OAuth credential refresh.
;;
;; fen does not run the PKCE login flow itself — the user runs
;; `pi login openai-codex` once on a host with pi-mono, which writes
;; ~/.pi/agent/auth.json. We refresh tokens ourselves when they expire
;; (or are about to), so multi-day sessions don't bounce the user back
;; to pi.
;;
;; Owns:
;;   - JWT base64url decode for the chatgpt_account_id claim
;;   - POST https://auth.openai.com/oauth/token (refresh_token grant)
;;   - lazy refresh via get-fresh-creds!: read auth.json, refresh if
;;     expiring within REFRESH-MARGIN-MS, write back atomically

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local base64 (require :fen.util.base64))
(local storage (require :fen.providers.openai_codex_keychain))

(local PROVIDER-ID :openai-codex)
(local TOKEN-URL "https://auth.openai.com/oauth/token")
(local CLIENT-ID "app_EMoamEEZ73f0CkXaXp7hrann")
(local ACCOUNT-CLAIM "https://api.openai.com/auth")
;; Refresh proactively if we'd otherwise hand out a token expiring within
;; this window. A single in-flight request can take tens of seconds, so
;; 60s gives plenty of headroom while not refreshing more than necessary.
(local REFRESH-MARGIN-MS (* 60 1000))

(fn split-jwt [token]
  (let [parts []]
    (each [part (string.gmatch token "[^.]+")]
      (table.insert parts part))
    (when (< (length parts) 2)
      (error "auth.openai_codex: malformed JWT (expected at least 2 segments)"))
    (values (. parts 1) (. parts 2) (. parts 3))))

(fn decode-jwt [token]
  "Decode a JWT and return its payload as a Lua table. Does NOT verify
   the signature — we trust the file we read from disk."
  (let [(_h payload-b64 _s) (split-jwt token)
        decoded (base64.decode-url payload-b64)
        (ok? value) (pcall json.decode decoded)]
    (if (and ok? (= (type value) :table))
        value
        (error "auth.openai_codex: JWT payload is not a JSON object"))))

(fn extract-account-id [access-token]
  "Pull the chatgpt_account_id from the JWT payload's
   `https://api.openai.com/auth` claim. Returns nil if absent or if the
   token cannot be parsed."
  (let [(ok? payload) (pcall decode-jwt access-token)]
    (if (not ok?)
        nil
        (let [auth (. payload ACCOUNT-CLAIM)
              id (and auth (. auth :chatgpt_account_id))]
          (if (and (= (type id) :string) (not= id ""))
              id
              nil)))))

(fn url-encode [s]
  (let [escaped (string.gsub (tostring s) "([^%w%-_%.~])"
                  (fn [c] (string.format "%%%02X" (string.byte c))))]
    escaped))

(fn form-encode [params]
  (let [parts []]
    (each [k v (pairs params)]
      (table.insert parts (.. (url-encode k) "=" (url-encode v))))
    (table.concat parts "&")))

(fn now-ms [] (* (os.time) 1000))

(fn post-token-request [body-form]
  (let [curl (require :cURL)
        chunks []
        easy (curl.easy)]
    (easy:setopt_url TOKEN-URL)
    (easy:setopt_post 1)
    (easy:setopt_postfields body-form)
    (easy:setopt_httpheader ["Content-Type: application/x-www-form-urlencoded"
                             "Accept: application/json"])
    (easy:setopt_timeout_ms 30000)
    (easy:setopt_connecttimeout_ms 10000)
    (easy:setopt_writefunction
      (fn [chunk] (table.insert chunks chunk) (length chunk)))
    (let [(ok? err) (pcall #(easy:perform))
          status (easy:getinfo_response_code)]
      (easy:close)
      (values ok? err status (table.concat chunks)))))

(fn refresh! [refresh-token]
  "POST to the token endpoint with refresh_token grant. Returns the fresh
   credential record on success, errors on transport or HTTP failure."
  (when (or (not refresh-token) (= refresh-token ""))
    (error "auth.openai_codex: refresh requires a non-empty refresh token"))
  (let [body (form-encode {:grant_type "refresh_token"
                           :refresh_token refresh-token
                           :client_id CLIENT-ID})
        (ok? err status raw) (post-token-request body)]
    (when (not ok?)
      (error (.. "auth.openai_codex: refresh transport failed: " (tostring err))))
    (when (or (< status 200) (>= status 300))
      (error (.. "auth.openai_codex: refresh HTTP " status ": " raw)))
    (let [(decoded? value) (pcall json.decode raw)]
      (when (not decoded?)
        (error (.. "auth.openai_codex: refresh response not JSON: " raw)))
      (when (or (not value.access_token) (not value.refresh_token)
                (not value.expires_in))
        (error (.. "auth.openai_codex: refresh response missing fields: " raw)))
      (let [account-id (extract-account-id value.access_token)]
        (when (not account-id)
          (error "auth.openai_codex: cannot extract chatgpt_account_id from refreshed token"))
        {:type :oauth
         :access value.access_token
         :refresh value.refresh_token
         :expires (+ (now-ms) (* value.expires_in 1000))
         :accountId account-id}))))

(fn expiring-soon? [creds]
  (or (not creds.expires)
      (<= creds.expires (+ (now-ms) REFRESH-MARGIN-MS))))

(fn user-error [msg]
  ;; `error(msg, 0)` suppresses the file:line: prefix Lua otherwise
  ;; prepends. These messages surface to the terminal verbatim, so the
  ;; prefix is just noise.
  (error msg 0))

(fn validate-stored-creds [creds]
  (when (not creds)
    (user-error
      "No Codex credentials found in auth.json — run `pi login openai-codex` first."))
  (when (not= creds.type :oauth)
    (user-error "Stored openai-codex credentials are not OAuth."))
  (when (or (not creds.access) (= creds.access ""))
    (user-error "Stored Codex access token is empty."))
  (when (or (not creds.refresh) (= creds.refresh ""))
    (user-error "Stored Codex refresh token is empty."))
  creds)

(fn configured? [?path]
  "Return true when auth.json contains a structurally usable openai-codex
   OAuth record. This is intentionally read-only and does not refresh tokens."
  (let [creds (storage.get PROVIDER-ID ?path)]
    (and creds
         (= creds.type :oauth)
         creds.access (not= creds.access "")
         creds.refresh (not= creds.refresh ""))))

(fn get-fresh-creds! [?path]
  "Read auth.json, refresh the openai-codex record if it's missing, expired,
   or expiring within REFRESH-MARGIN-MS, and persist any refresh atomically.
   Errors with a friendly message if no credentials exist."
  (let [creds (validate-stored-creds (storage.get PROVIDER-ID ?path))]
    (if (expiring-soon? creds)
        (let [fresh (refresh! creds.refresh)]
          (storage.set PROVIDER-ID fresh ?path)
          (log.info "auth.openai_codex: refreshed access token")
          fresh)
        creds)))

{: PROVIDER-ID
 : TOKEN-URL
 : CLIENT-ID
 : decode-jwt
 : extract-account-id
 : refresh!
 : expiring-soon?
 : configured?
 : get-fresh-creds!
 : form-encode
 : url-encode}
