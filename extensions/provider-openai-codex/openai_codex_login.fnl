;; Native PKCE login flow for ChatGPT Codex.
;;
;; Walks the user through OAuth without requiring pi-mono: prints the
;; authorize URL, accepts the callback URL (or just the code) pasted
;; back in over stdin, exchanges the code at auth.openai.com/oauth/token,
;; extracts the chatgpt_account_id from the resulting JWT, and writes
;; the credentials atomically to fen's writable auth.json path.
;;
;; Why no localhost callback server: a real listener needs a sockets
;; binding (luasocket/luaposix) we deliberately don't carry; manual
;; paste covers v1 and matches pi-mono's documented fallback. See #38.

(local json (require :fen.util.json))
(local http (require :fen.util.http))
(local base64 (require :fen.util.base64))
(local sha256 (require :fen.util.sha256))
(local random (require :fen.util.random))
(local oauth (require :fen.extensions.provider_openai_codex.openai_codex_oauth))
(local storage (require :fen.extensions.provider_openai_codex.openai_codex_keychain))

(local AUTHORIZE-URL "https://auth.openai.com/oauth/authorize")
(local REDIRECT-URI "http://localhost:1455/auth/callback")
(local SCOPE "openid profile email offline_access")
(local ORIGINATOR "fen")

(fn user-error [msg]
  ;; `error msg 0` suppresses Lua's `file:line:` prefix so the operator
  ;; sees the raw message. Same convention as openai_codex_oauth.
  (error msg 0))

(fn now-ms [] (* (os.time) 1000))

(fn describe-fields [t]
  "Return a sorted, comma-separated list of top-level keys in `t`. Used to
   describe a token-endpoint response in error messages without dumping
   values — values may include access/refresh tokens we should not log."
  (if (not= (type t) :table)
      "(non-object)"
      (let [keys []]
        (each [k _ (pairs t)]
          (table.insert keys (tostring k)))
        (table.sort keys)
        (if (= (length keys) 0)
            "(empty object)"
            (table.concat keys ", ")))))

(fn truncate-snippet [s]
  "Bound-clip a body for inclusion in transport/JSON-parse errors. Trims
   to a length where token-shaped strings (~100+ chars) won't fit even if
   they leaked into a malformed response. Best-effort: a server returning
   a very short access token would still surface in the snippet."
  (let [s (or s "")
        max 64]
    (if (<= (length s) max)
        s
        (.. (string.sub s 1 max) "…(" (tostring (- (length s) max))
            " more bytes)"))))

(fn random-hex [n-bytes]
  (let [raw (random.bytes n-bytes)
        out []]
    (for [i 1 (length raw)]
      (table.insert out (string.format "%02x" (string.byte raw i))))
    (table.concat out)))

;; @doc fen.extensions.provider_openai_codex.openai_codex_login.generate-pkce
;; kind: function
;; signature: (generate-pkce) -> {:verifier :challenge}
;; summary: Generate a fresh PKCE verifier/challenge pair using platform randomness, SHA-256, and base64url encoding.
;; tags: codex auth login pkce
(fn generate-pkce []
  "Return a fresh PKCE pair: {:verifier ... :challenge ...} where
   verifier is 32 random bytes base64url-encoded and challenge is
   base64url(SHA256(verifier))."
  (let [verifier-bytes (random.bytes 32)
        verifier (base64.encode-url verifier-bytes)
        challenge (base64.encode-url (sha256.digest verifier))]
    {: verifier : challenge}))

;; @doc fen.extensions.provider_openai_codex.openai_codex_login.build-authorize-url
;; kind: function
;; signature: (build-authorize-url pkce state) -> string
;; summary: Compose the ChatGPT OAuth authorization URL with PKCE challenge, state, scope, redirect URI, and Codex flow flags.
;; tags: codex auth login pkce
(fn build-authorize-url [pkce state]
  "Compose the authorization URL the user opens in their browser.
   `pkce` must include :challenge; `state` is the random anti-CSRF token."
  (let [params {:response_type "code"
                :client_id oauth.CLIENT-ID
                :redirect_uri REDIRECT-URI
                :scope SCOPE
                :code_challenge pkce.challenge
                :code_challenge_method "S256"
                :state state
                :id_token_add_organizations "true"
                :codex_cli_simplified_flow "true"
                :originator ORIGINATOR}]
    (.. AUTHORIZE-URL "?" (oauth.form-encode params))))

;; @doc fen.extensions.provider_openai_codex.openai_codex_login.extract-query-param
;; kind: function
;; signature: (extract-query-param query key) -> string|nil
;; summary: Extract and URL-decode one parameter from an OAuth callback query string.
;; tags: codex auth login parse
(fn extract-query-param [query key]
  "Lift `key=value` out of an `&`-separated query string. Returns the
   URL-decoded value, or nil."
  (var found nil)
  (each [pair (string.gmatch query "[^&]+")]
    (when (= nil found)
      (let [eq (string.find pair "=" 1 true)]
        (when eq
          (let [k (string.sub pair 1 (- eq 1))
                v (string.sub pair (+ eq 1))]
            (when (= k key)
              ;; URL decode: '+' → ' ', then %XX → byte.
              (let [step1 (string.gsub v "%+" " ")
                    step2 (string.gsub step1 "%%(%x%x)"
                            (fn [hex] (string.char (tonumber hex 16))))]
                (set found step2))))))))
  found)

;; @doc fen.extensions.provider_openai_codex.openai_codex_login.parse-authorization-input
;; kind: function
;; signature: (parse-authorization-input input) -> {:code :state}
;; summary: Parse pasted Codex authorization input as full callback URL, raw query, code#state shorthand, or bare code.
;; tags: codex auth login parse
(fn parse-authorization-input [input]
  "Accept the full callback URL the user pastes (e.g.
   'http://localhost:1455/auth/callback?code=...&state=...'),
   the bare code, or a 'code#state' shorthand. Returns
   {:code ... :state ...} where :state may be nil."
  (let [trimmed (or (string.match (or input "") "^%s*(.-)%s*$") "")]
    (if (= trimmed "")
        {}
        (let [(_ q-start) (string.find trimmed "?" 1 true)]
          (if q-start
              ;; Looks like a URL with a query string.
              (let [query (string.sub trimmed (+ q-start 1))]
                {:code (extract-query-param query "code")
                 :state (extract-query-param query "state")})
              (if (string.find trimmed "#" 1 true)
                  (let [(code state) (string.match trimmed "^([^#]+)#(.*)$")]
                    {: code : state})
                  (if (string.find trimmed "code=" 1 true)
                      ;; raw `code=...&state=...` paste
                      {:code (extract-query-param trimmed "code")
                       :state (extract-query-param trimmed "state")}
                      ;; Just the bare code.
                      {:code trimmed})))))))

;; @doc fen.extensions.provider_openai_codex.openai_codex_login.exchange-code!
;; kind: function
;; signature: (exchange-code! code verifier) -> CredentialRecord
;; summary: Exchange an authorization code and PKCE verifier for Codex OAuth credentials, validating required token response fields.
;; tags: codex auth login oauth
(fn exchange-code! [code verifier]
  "POST to the token endpoint with grant_type=authorization_code.
   Returns the credential record on success; errors on transport or
   HTTP failure or missing fields."
  (let [body (oauth.form-encode {:grant_type "authorization_code"
                                 :code code
                                 :code_verifier verifier
                                 :redirect_uri REDIRECT-URI
                                 :client_id oauth.CLIENT-ID})
        resp (http.request
               {:method :POST
                :url oauth.TOKEN-URL
                :headers {:content-type "application/x-www-form-urlencoded"
                          :accept "application/json"}
                :body body
                :timeout-ms 30000
                :connect-timeout-ms 10000})]
    (when resp.error
      (user-error (.. "openai-codex login: token exchange transport failed: "
                      resp.error)))
    (when (or (< resp.status 200) (>= resp.status 300))
      ;; 4xx/5xx bodies are OAuth error envelopes ({"error":"...",
      ;; "error_description":"..."}) — no tokens to leak. Surface verbatim
      ;; so the operator can read the server's reason directly.
      (user-error (.. "openai-codex login: token exchange HTTP " resp.status ": "
                      (or resp.body ""))))
    (let [(decoded? value) (pcall json.decode resp.body)]
      (when (not decoded?)
        ;; Body claimed 2xx but isn't JSON — could be an HTML error page or
        ;; a malformed proxy response. Truncate so a token-shaped string
        ;; doesn't fit even if one leaked through.
        (user-error (.. "openai-codex login: token response not JSON (snippet: "
                        (truncate-snippet resp.body) ")")))
      (when (or (not value.access_token) (not value.refresh_token)
                (not value.expires_in))
        ;; A 2xx with a JSON body that's missing fields might still contain
        ;; an access_token (e.g. refresh_token absent). Don't dump the
        ;; body — list which fields the server returned instead.
        (user-error (.. "openai-codex login: token response missing required "
                        "fields. Server returned: " (describe-fields value))))
      (let [account-id (oauth.extract-account-id value.access_token)]
        (when (not account-id)
          (user-error
            "openai-codex login: cannot extract chatgpt_account_id from access token"))
        {:type :oauth
         :access value.access_token
         :refresh value.refresh_token
         :expires (+ (now-ms) (* value.expires_in 1000))
         :accountId account-id}))))

(fn read-line! [prompt]
  "Print the prompt and read a single trimmed line from stdin.
   Errors if stdin is closed before a line arrives."
  (io.write prompt)
  (io.flush)
  (let [line (io.read "*l")]
    (when (= nil line)
      (user-error "openai-codex login: no input received (stdin closed)"))
    (or (string.match line "^%s*(.-)%s*$") "")))

;; @doc fen.extensions.provider_openai_codex.openai_codex_login.login!
;; kind: function
;; signature: (login! ?path) -> CredentialRecord
;; summary: Run the manual PKCE login flow, prompt for the callback code, exchange it, persist credentials, and print account status.
;; tags: codex auth login oauth
(fn login! [?path]
  "Run the full PKCE login flow. Prints the authorize URL, prompts for
   the redirect URL or code, exchanges the code, and writes the
   credential record atomically. Returns the persisted record."
  (let [pkce (generate-pkce)
        state (random-hex 16)
        url (build-authorize-url pkce state)]
    (io.write "Open this URL in a browser to sign in to ChatGPT:\n\n  ")
    (io.write url)
    (io.write
      "\n\nThe browser will be redirected to a localhost URL that fails to load — that is expected.\nPaste the full redirect URL (or just the `code` value) here:\n")
    (let [parsed (parse-authorization-input (read-line! "> "))
          code parsed.code
          got-state parsed.state]
      (when (or (not code) (= code ""))
        (user-error "openai-codex login: no authorization code in pasted input"))
      (when (and got-state (not= got-state state))
        (user-error "openai-codex login: state mismatch — possible CSRF, aborting"))
      (let [creds (exchange-code! code pkce.verifier)]
        (storage.set oauth.PROVIDER-ID creds ?path)
        (io.write "\nSigned in as account ")
        (io.write creds.accountId)
        (io.write ". Credentials written to ")
        (io.write (or ?path (storage.default-auth-path)))
        (io.write ".\n")
        creds))))

;; @doc fen.extensions.provider_openai_codex.openai_codex_login.logout!
;; kind: function
;; signature: (logout! ?path) -> boolean
;; summary: Remove the openai-codex credential record from auth.json and report whether anything was deleted.
;; tags: codex auth login oauth
(fn logout! [?path]
  "Remove the openai-codex record from auth.json. No-op (with a
   user-visible message) if no record exists."
  (let [data (storage.load ?path)
        existed? (not= nil (. data oauth.PROVIDER-ID))]
    (if existed?
        (do
          (tset data oauth.PROVIDER-ID nil)
          (storage.save data ?path)
          (io.write "openai-codex credentials removed from ")
          (io.write (or ?path (storage.default-auth-path)))
          (io.write ".\n")
          true)
        (do
          (io.write "openai-codex: no stored credentials to remove.\n")
          false))))

;; @doc fen.extensions.provider_openai_codex.openai_codex_login.AUTHORIZE-URL
;; kind: data
;; signature: string
;; summary: ChatGPT OAuth authorization endpoint used by the manual Codex PKCE login flow.
;; tags: codex auth login metadata
;; @doc fen.extensions.provider_openai_codex.openai_codex_login.REDIRECT-URI
;; kind: data
;; signature: string
;; summary: Localhost redirect URI registered for the ChatGPT Codex OAuth client and shown in pasted callback URLs.
;; tags: codex auth login metadata
;; @doc fen.extensions.provider_openai_codex.openai_codex_login.SCOPE
;; kind: data
;; signature: string
;; summary: OAuth scope string requesting identity, email/profile, and offline refresh-token access.
;; tags: codex auth login metadata
;; @doc fen.extensions.provider_openai_codex.openai_codex_login.ORIGINATOR
;; kind: data
;; signature: string
;; summary: Originator value sent in the authorization URL to identify fen's simplified Codex login flow.
;; tags: codex auth login metadata
{: AUTHORIZE-URL
 : REDIRECT-URI
 : SCOPE
 : ORIGINATOR
 : generate-pkce
 : build-authorize-url
 : parse-authorization-input
 : extract-query-param
 : exchange-code!
 : login!
 : logout!}
