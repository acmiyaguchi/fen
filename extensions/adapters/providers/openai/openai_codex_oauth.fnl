;; OpenAI Codex OAuth credential refresh.
;;
;; The initial PKCE login is handled by openai_codex_login.fnl
;; (`fen --login openai-codex`); this module owns the refresh half:
;; reading the persisted record, refreshing tokens before they expire,
;; and writing the result atomically to fen's writable auth path.
;; Pi-mono auth files are not read as fallbacks.
;;
;; Owns:
;;   - JWT base64url decode for the chatgpt_account_id claim
;;   - POST https://auth.openai.com/oauth/token (refresh_token grant)
;;   - lazy refresh via get-fresh-creds!: read auth.json, refresh if
;;     expiring within REFRESH-MARGIN-MS, write back atomically

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local base64 (require :fen.util.base64))
(local http (require :fen.util.http))
(local storage (require :fen.extensions.provider_openai.openai_codex_keychain))

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

;; @doc fen.extensions.provider_openai.openai_codex_oauth.decode-jwt
;; kind: function
;; signature: (decode-jwt token) -> table
;; summary: Decode a JWT payload into a Lua table without signature verification for trusted on-disk Codex tokens.
;; tags: codex auth oauth jwt
(fn decode-jwt [token]
  "Decode a JWT and return its payload as a Lua table. Does NOT verify
   the signature — we trust the file we read from disk."
  (let [(_h payload-b64 _s) (split-jwt token)
        decoded (base64.decode-url payload-b64)
        (ok? value) (pcall json.decode decoded)]
    (if (and ok? (= (type value) :table))
        value
        (error "auth.openai_codex: JWT payload is not a JSON object"))))

;; @doc fen.extensions.provider_openai.openai_codex_oauth.extract-account-id
;; kind: function
;; signature: (extract-account-id access-token) -> string|nil
;; summary: Extract chatgpt_account_id from the OpenAI auth claim in a Codex access-token JWT, returning nil on parse failure.
;; tags: codex auth oauth jwt
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

;; @doc fen.extensions.provider_openai.openai_codex_oauth.url-encode
;; kind: function
;; signature: (url-encode s) -> string
;; summary: Percent-encode one OAuth form component using the unreserved character set required by application/x-www-form-urlencoded.
;; tags: codex auth oauth form
(fn url-encode [s]
  (let [escaped (string.gsub (tostring s) "([^%w%-_%.~])"
                  (fn [c] (string.format "%%%02X" (string.byte c))))]
    escaped))

;; @doc fen.extensions.provider_openai.openai_codex_oauth.form-encode
;; kind: function
;; signature: (form-encode params) -> string
;; summary: Encode OAuth form parameters as an ampersand-joined application/x-www-form-urlencoded body.
;; tags: codex auth oauth form
(fn form-encode [params]
  (let [parts []]
    (each [k v (pairs params)]
      (table.insert parts (.. (url-encode k) "=" (url-encode v))))
    (table.concat parts "&")))

(fn now-ms [] (* (os.time) 1000))

;; @doc fen.extensions.provider_openai.openai_codex_oauth.refresh!
;; kind: function
;; signature: (refresh! refresh-token) -> CredentialRecord
;; summary: Exchange a refresh token at the OpenAI OAuth token endpoint and return a fresh Codex credential record.
;; tags: codex auth oauth refresh
(fn refresh! [refresh-token]
  "POST to the token endpoint with refresh_token grant. Returns the fresh
   credential record on success, errors on transport or HTTP failure."
  (when (or (not refresh-token) (= refresh-token ""))
    (error "auth.openai_codex: refresh requires a non-empty refresh token"))
  (let [body (form-encode {:grant_type "refresh_token"
                           :refresh_token refresh-token
                           :client_id CLIENT-ID})
        resp (http.request
               {:method :POST
                :url TOKEN-URL
                :headers {:content-type "application/x-www-form-urlencoded"
                          :accept "application/json"}
                :body body
                :timeout-ms 30000
                :connect-timeout-ms 10000})]
    (when resp.error
      (error (.. "auth.openai_codex: refresh transport failed: " resp.error)))
    (when (or (< resp.status 200) (>= resp.status 300))
      (error (.. "auth.openai_codex: refresh HTTP " resp.status ": " resp.body)))
    (let [raw resp.body
          (decoded? value) (pcall json.decode raw)]
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

;; @doc fen.extensions.provider_openai.openai_codex_oauth.expiring-soon?
;; kind: function
;; signature: (expiring-soon? creds) -> boolean
;; summary: Return true when stored Codex credentials are missing expiry or expire within the proactive refresh margin.
;; tags: codex auth oauth refresh
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
      "No Codex credentials found in auth.json — run `fen --login openai-codex` first."))
  (when (not= creds.type :oauth)
    (user-error "Stored openai-codex credentials are not OAuth."))
  (when (or (not creds.access) (= creds.access ""))
    (user-error "Stored Codex access token is empty."))
  (when (or (not creds.refresh) (= creds.refresh ""))
    (user-error "Stored Codex refresh token is empty."))
  creds)

;; @doc fen.extensions.provider_openai.openai_codex_oauth.configured?
;; kind: function
;; signature: (configured? ?path) -> boolean
;; summary: Check whether auth.json contains a structurally usable openai-codex OAuth record without refreshing it.
;; tags: codex auth oauth status
(fn configured? [?path]
  "Return true when auth.json contains a structurally usable openai-codex
   OAuth record. This is intentionally read-only and does not refresh tokens."
  (let [creds (storage.get PROVIDER-ID ?path)]
    (and creds
         (= creds.type :oauth)
         creds.access (not= creds.access "")
         creds.refresh (not= creds.refresh ""))))

;; @doc fen.extensions.provider_openai.openai_codex_oauth.get-fresh-creds!
;; kind: function
;; signature: (get-fresh-creds! ?path) -> CredentialRecord
;; summary: Load Codex credentials, refresh and persist them when near expiry, or raise a friendly login-required error.
;; tags: codex auth oauth refresh
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

;; @doc fen.extensions.provider_openai.openai_codex_oauth.PROVIDER-ID
;; kind: data
;; signature: keyword
;; summary: Auth storage provider id used for openai-codex credential records in auth.json.
;; tags: codex auth oauth metadata
;; @doc fen.extensions.provider_openai.openai_codex_oauth.TOKEN-URL
;; kind: data
;; signature: string
;; summary: OpenAI OAuth token endpoint used for Codex PKCE exchange and refresh-token grants.
;; tags: codex auth oauth metadata
;; @doc fen.extensions.provider_openai.openai_codex_oauth.CLIENT-ID
;; kind: data
;; signature: string
;; summary: OAuth client id used by the ChatGPT Codex login and refresh flows.
;; tags: codex auth oauth metadata
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
