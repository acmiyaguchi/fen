;; Unit tests for the Codex OAuth helpers. Network round-trips are
;; integration-tested manually; here we cover JWT decode, account-id
;; extraction, form/url encoding, and the expiring-soon? threshold.

(local codex (require :fen.extensions.provider_openai_codex.openai_codex_oauth))
(local h (require :fen.testing))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

;; Precomputed JWT payload (base64url, no padding):
;;   {"https://api.openai.com/auth":{"chatgpt_account_id":"acc_test"}}
(local PAYLOAD-B64
  "eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjX3Rlc3QifX0")
(local FAKE-JWT (.. "header." PAYLOAD-B64 ".signature"))

(describe "auth.openai_codex.decode-jwt"
  (fn []
    (it "returns the parsed payload object"
      (fn []
        (let [payload (codex.decode-jwt FAKE-JWT)
              auth (. payload "https://api.openai.com/auth")]
          (assert.is_table auth)
          (assert.are.equal "acc_test" auth.chatgpt_account_id))))

    (it "errors on a malformed JWT (single segment)"
      (fn []
        (let [(ok? _) (pcall codex.decode-jwt "notajwt")]
          (assert.is_false ok?))))))

(describe "auth.openai_codex.extract-account-id"
  (fn []
    (it "pulls chatgpt_account_id from the auth claim"
      (fn []
        (assert.are.equal "acc_test" (codex.extract-account-id FAKE-JWT))))

    (it "returns nil for tokens without the auth claim"
      (fn []
        ;; Precomputed: {"sub":"u","aud":"x"} — no auth claim.
        (let [no-auth-jwt "header.eyJzdWIiOiJ1IiwiYXVkIjoieCJ9.sig"]
          (assert.is_nil (codex.extract-account-id no-auth-jwt)))))

    (it "returns nil for malformed tokens (no throw)"
      (fn []
        (assert.is_nil (codex.extract-account-id "garbage"))))))

(describe "auth.openai_codex.url-encode and form-encode"
  (fn []
    (it "leaves unreserved chars alone"
      (fn []
        (assert.are.equal "abc-_.~XYZ123"
                          (codex.url-encode "abc-_.~XYZ123"))))

    (it "percent-encodes special characters"
      (fn []
        (assert.are.equal "a%20b" (codex.url-encode "a b"))
        (assert.are.equal "a%2Bb" (codex.url-encode "a+b"))
        (assert.are.equal "a%2Fb" (codex.url-encode "a/b"))))

    (it "form-encodes a flat params table"
      (fn []
        ;; Order is undefined for `each` over a table; verify by parsing
        ;; back into a set of pairs.
        (let [encoded (codex.form-encode
                        {:grant_type "refresh_token"
                         :refresh_token "rt+slash/value"
                         :client_id "app_xyz"})
              parts {}]
          (each [pair (string.gmatch encoded "[^&]+")]
            (let [eq (string.find pair "=" 1 true)
                  k (string.sub pair 1 (- eq 1))
                  v (string.sub pair (+ eq 1))]
              (tset parts k v)))
          (assert.are.equal "refresh_token" (. parts :grant_type))
          (assert.are.equal "rt%2Bslash%2Fvalue" (. parts :refresh_token))
          (assert.are.equal "app_xyz" (. parts :client_id)))))))

(describe "auth.openai_codex.configured?"
  (fn []
    (var tmp nil)

    (before_each
      (fn []
        (set tmp (make-tmpdir))))

    (after_each
      (fn []
        (when tmp (rmtree tmp))))

    (fn auth-path []
      (.. tmp "/auth.json"))

    (it "is false when no stored record exists"
      (fn []
        (assert.is_falsy (codex.configured? (auth-path)))))

    (it "is false for incomplete stored credentials"
      (fn []
        (write-file (auth-path)
                    "{\"openai-codex\":{\"type\":\"oauth\",\"access\":\"a\"}}")
        (assert.is_falsy (codex.configured? (auth-path)))))

    (it "is true for stored OAuth credentials without refreshing"
      (fn []
        (write-file (auth-path)
                    "{\"openai-codex\":{\"type\":\"oauth\",\"access\":\"a\",\"refresh\":\"r\"}}")
        (assert.is_true (codex.configured? (auth-path)))))))

(describe "auth.openai_codex.expiring-soon?"
  (fn []
    (it "is true when expires is in the past"
      (fn []
        (assert.is_true (codex.expiring-soon? {:expires 0}))))

    (it "is true when expires is within 60 seconds from now"
      (fn []
        (let [now-ms (* (os.time) 1000)
              soon (+ now-ms (* 30 1000))]
          (assert.is_true (codex.expiring-soon? {:expires soon})))))

    (it "is false when expires is well in the future"
      (fn []
        (let [now-ms (* (os.time) 1000)
              far (+ now-ms (* 3600 1000))]
          (assert.is_false (codex.expiring-soon? {:expires far})))))

    (it "is true when expires is missing"
      (fn []
        (assert.is_true (codex.expiring-soon? {}))))))
