;; First-party OpenAI Codex subscription provider + auth backend extension.

(local codex-responses (require :fen.extensions.provider_openai_codex.openai_codex_responses))
(local codex-auth (require :fen.extensions.provider_openai_codex.openai_codex_oauth))
(local codex-login (require :fen.extensions.provider_openai_codex.openai_codex_login))
(local storage (require :fen.extensions.provider_openai_codex.openai_codex_keychain))

(fn auth-status-info []
  "Rows surfaced under the `auth:` line in /status so an operator can see
   exactly where fen writes auth.json and which pi-mono files are read-only
   fallbacks. Used for debugging — \"why isn't my login persisting\",
   \"is fen pointing at the real ~/.pi/agent\", etc."
  (let [write-path (storage.default-auth-path)
        paths (storage.candidate-read-auth-paths)
        rows [{:label "auth.json write" :value write-path}]
        fen-env (os.getenv "FEN_AUTH_DIR")]
    (when fen-env
      (table.insert rows {:label "write override" :value "$FEN_AUTH_DIR"}))
    (each [i path (ipairs paths)]
      (when (and (> i 1) (not= path write-path))
        (table.insert rows {:label "read fallback" :value path})))
    rows))

(fn provider-spec [provider name default-model auth-backend]
  (let [spec {}]
    (each [k v (pairs provider)] (tset spec k v))
    (set spec.name name)
    (set spec.default-model default-model)
    (set spec.auth-backend auth-backend)
    spec))

(local M {})

(fn M.register [api]

(api.register :auth-backend
              {:name :openai-codex
               :description "ChatGPT subscription PKCE OAuth credentials shared with the Codex CLI."
               :configured? codex-auth.configured?
               :get-fresh-creds! codex-auth.get-fresh-creds!
               :login! codex-login.login!
               :logout! codex-login.logout!
               :status-info auth-status-info})

;; @doc register-site:provider:openai-codex
;; summary: ChatGPT subscription/Codex Responses provider using the openai-codex OAuth auth backend and default gpt-5.5 model.
;; tags: provider openai codex oauth
(api.register :provider
              (provider-spec codex-responses :openai-codex :gpt-5.5
                             :openai-codex))

  true)

M
