;; Unit tests for the Codex PKCE login flow. Network round-trips are
;; integration-tested manually; here we cover PKCE generation shape,
;; redirect-input parsing, authorization URL composition, exchange-code!
;; against a mocked HTTP backend, and the logout merge.

;; Mock fen.util.http BEFORE the login module is required, so its
;; (require :fen.util.http) at top of the file resolves to the fake.
(local recorded {})
(tset package.loaded :fen.util.http
      {:request (fn [opts]
                  (set recorded.opts opts)
                  recorded.response)})

(local login (require :fen.extensions.provider_openai.openai_codex_login))
(local oauth (require :fen.extensions.provider_openai.openai_codex_oauth))
(local storage (require :fen.extensions.provider_openai.openai_codex_keychain))
(local json (require :fen.util.json))
(local h (require :fen.testing))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

;; Reusable fixture: a JWT whose payload has the chatgpt_account_id claim.
(local PAYLOAD-B64
  "eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjX3Rlc3QifX0")
(local FAKE-JWT (.. "header." PAYLOAD-B64 ".signature"))

(describe "openai_codex_login.generate-pkce"
  (fn []
    (it "returns base64url-shaped verifier and challenge"
      (fn []
        (let [pkce (login.generate-pkce)]
          (assert.is_string pkce.verifier)
          (assert.is_string pkce.challenge)
          ;; 32 random bytes base64url-encoded → 43 chars (no padding).
          (assert.are.equal 43 (length pkce.verifier))
          ;; SHA-256 → 32 bytes → 43 chars base64url.
          (assert.are.equal 43 (length pkce.challenge))
          ;; No padding `=`.
          (assert.is_nil (string.find pkce.verifier "=" 1 true))
          (assert.is_nil (string.find pkce.challenge "=" 1 true))
          ;; Only base64url chars.
          (assert.is_truthy (string.match pkce.verifier "^[A-Za-z0-9_-]+$"))
          (assert.is_truthy (string.match pkce.challenge "^[A-Za-z0-9_-]+$")))))

    (it "produces different verifiers across calls"
      (fn []
        (let [a (login.generate-pkce)
              b (login.generate-pkce)]
          (assert.is_not.equal a.verifier b.verifier)
          (assert.is_not.equal a.challenge b.challenge))))))

(describe "openai_codex_login.parse-authorization-input"
  (fn []
    (it "extracts code and state from a full callback URL"
      (fn []
        (let [parsed (login.parse-authorization-input
                       "http://localhost:1455/auth/callback?code=abc123&state=xyz")]
          (assert.are.equal "abc123" parsed.code)
          (assert.are.equal "xyz" parsed.state))))

    (it "extracts code from URL without state"
      (fn []
        (let [parsed (login.parse-authorization-input
                       "http://localhost:1455/auth/callback?code=onlycode")]
          (assert.are.equal "onlycode" parsed.code)
          (assert.is_nil parsed.state))))

    (it "accepts a bare code"
      (fn []
        (let [parsed (login.parse-authorization-input "barecode-42")]
          (assert.are.equal "barecode-42" parsed.code)
          (assert.is_nil parsed.state))))

    (it "splits a code#state shorthand"
      (fn []
        (let [parsed (login.parse-authorization-input "thecode#thestate")]
          (assert.are.equal "thecode" parsed.code)
          (assert.are.equal "thestate" parsed.state))))

    (it "strips leading and trailing whitespace"
      (fn []
        (let [parsed (login.parse-authorization-input "  trimmed-code  ")]
          (assert.are.equal "trimmed-code" parsed.code))))

    (it "returns empty table for empty/whitespace input"
      (fn []
        (let [parsed (login.parse-authorization-input "   ")]
          (assert.is_nil parsed.code)
          (assert.is_nil parsed.state))))

    (it "URL-decodes percent-encoded values"
      (fn []
        (let [parsed (login.parse-authorization-input
                       "http://localhost:1455/auth/callback?code=a%2Fb%2Bc&state=s%20t")]
          (assert.are.equal "a/b+c" parsed.code)
          (assert.are.equal "s t" parsed.state))))))

(describe "openai_codex_login.build-authorize-url"
  (fn []
    (it "includes every required query parameter"
      (fn []
        (let [url (login.build-authorize-url
                    {:challenge "CHAL"} "STATE")]
          (assert.is_truthy (string.find url "^https://auth%.openai%.com/oauth/authorize%?"))
          ;; Required PKCE + OAuth params.
          (assert.is_truthy (string.find url "response_type=code"))
          (assert.is_truthy (string.find url
                              (.. "client_id=" oauth.CLIENT-ID) 1 true))
          (assert.is_truthy (string.find url "code_challenge=CHAL"))
          (assert.is_truthy (string.find url "code_challenge_method=S256"))
          (assert.is_truthy (string.find url "state=STATE"))
          ;; Codex-specific flags.
          (assert.is_truthy
            (string.find url "codex_cli_simplified_flow=true"))
          (assert.is_truthy
            (string.find url "id_token_add_organizations=true"))
          (assert.is_truthy (string.find url "originator=fen"))
          ;; Redirect URI is URL-encoded — `:` becomes %3A, `/` becomes %2F.
          (assert.is_truthy
            (string.find url "redirect_uri=http%%3A%%2F%%2Flocalhost%%3A1455"
                         1 false)))))))

(describe "openai_codex_login.exchange-code!"
  (fn []
    (before_each (fn [] (set recorded.opts nil) (set recorded.response nil)))

    (it "POSTs grant_type=authorization_code and returns the credential record"
      (fn []
        (set recorded.response
             {:status 200
              :body (json.encode {:access_token FAKE-JWT
                                  :refresh_token "rt-fresh"
                                  :expires_in 3600})})
        (let [creds (login.exchange-code! "the-code" "the-verifier")]
          (assert.are.equal :oauth creds.type)
          (assert.are.equal FAKE-JWT creds.access)
          (assert.are.equal "rt-fresh" creds.refresh)
          (assert.are.equal "acc_test" creds.accountId)
          ;; Body is form-encoded with grant_type=authorization_code.
          (let [body recorded.opts.body]
            (assert.is_truthy (string.find body "grant_type=authorization_code" 1 true))
            (assert.is_truthy (string.find body "code=the%-code"))
            (assert.is_truthy (string.find body "code_verifier=the%-verifier"))
            (assert.is_truthy
              (string.find body (.. "client_id=" oauth.CLIENT-ID) 1 true)))
          (assert.are.equal "POST" (string.upper (tostring recorded.opts.method)))
          (assert.are.equal oauth.TOKEN-URL recorded.opts.url))))

    (it "errors on non-2xx status with the body in the message"
      (fn []
        (set recorded.response {:status 400 :body "{\"error\":\"bad_code\"}"})
        (let [(ok? err) (pcall login.exchange-code! "bad" "verifier")]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err) "HTTP 400" 1 true))
          (assert.is_truthy (string.find (tostring err) "bad_code" 1 true)))))

    (it "errors on transport failure"
      (fn []
        (set recorded.response {:error "tls handshake failed"})
        (let [(ok? err) (pcall login.exchange-code! "code" "verifier")]
          (assert.is_false ok?)
          (assert.is_truthy
            (string.find (tostring err) "tls handshake failed" 1 true)))))

    (it "errors when the response is missing required fields"
      (fn []
        (set recorded.response
             {:status 200 :body (json.encode {:access_token FAKE-JWT})})
        (let [(ok? err) (pcall login.exchange-code! "c" "v")]
          (assert.is_false ok?)
          (assert.is_truthy
            (string.find (tostring err) "missing required fields" 1 true)))))

    (it "does NOT include the access_token in the missing-fields error"
      ;; Security: a 2xx with access_token but no refresh/expires_in still
      ;; carries a real token. Error must surface the field list, not the
      ;; raw body. Regression guard for the original review item.
      (fn []
        (set recorded.response
             {:status 200 :body (json.encode {:access_token FAKE-JWT})})
        (let [(ok? err) (pcall login.exchange-code! "c" "v")
              msg (tostring err)]
          (assert.is_false ok?)
          (assert.is_nil (string.find msg FAKE-JWT 1 true))
          ;; But the field list IS present, so the operator can debug.
          (assert.is_truthy (string.find msg "access_token" 1 true)))))

    (it "truncates non-JSON bodies in the parse-failure error"
      (fn []
        (let [long-body (string.rep "x" 500)]
          (set recorded.response {:status 200 :body long-body})
          (let [(ok? err) (pcall login.exchange-code! "c" "v")
                msg (tostring err)]
            (assert.is_false ok?)
            (assert.is_truthy (string.find msg "not JSON" 1 true))
            ;; 500 - 64 = 436 more bytes after the snippet.
            (assert.is_truthy (string.find msg "436 more bytes" 1 true))))))))

(describe "openai_codex_login.logout!"
  (fn []
    (var tmp nil)

    (before_each (fn [] (set tmp (make-tmpdir))))
    (after_each (fn [] (when tmp (rmtree tmp))))

    (fn auth-path [] (.. tmp "/auth.json"))

    (it "removes only the openai-codex record, preserving siblings"
      (fn []
        (write-file (auth-path)
                    (json.encode {:openai-codex {:type :oauth
                                                 :access "a"
                                                 :refresh "r"}
                                  :other {:keep "this"}}))
        (assert.is_true (login.logout! (auth-path)))
        (let [data (storage.load (auth-path))]
          (assert.is_nil (. data :openai-codex))
          (assert.are.equal "this" (. data :other :keep)))))

    (it "is a no-op when no codex record exists"
      (fn []
        (write-file (auth-path) (json.encode {:other {:keep "this"}}))
        (assert.is_false (login.logout! (auth-path)))
        (let [data (storage.load (auth-path))]
          (assert.are.equal "this" (. data :other :keep)))))

    (it "is a no-op when the file is missing entirely"
      (fn []
        (assert.is_false (login.logout! (auth-path)))))))
