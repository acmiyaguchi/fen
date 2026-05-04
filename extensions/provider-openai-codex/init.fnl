;; First-party OpenAI Codex subscription provider + auth backend extension.

(local extensions (require :fen.core.extensions))
(local codex-responses (require :fen.extensions.provider_openai_codex.openai_codex_responses))
(local codex-auth (require :fen.extensions.provider_openai_codex.openai_codex_oauth))
(local codex-login (require :fen.extensions.provider_openai_codex.openai_codex_login))
(local storage (require :fen.extensions.provider_openai_codex.openai_codex_keychain))

(fn auth-status-info []
  "Rows surfaced under the `auth:` line in /status so an operator can see
   exactly which auth.json the runtime is reading and which env var (if
   any) relocated it. Used for debugging — \"why isn't my login
   persisting\", \"is fen pointing at the real ~/.pi/agent\", etc."
  (let [path (storage.default-auth-path)
        fen-env (os.getenv "FEN_AUTH_DIR")
        pi-env (os.getenv "PI_CODING_AGENT_DIR")
        override (if fen-env "FEN_AUTH_DIR"
                     pi-env "PI_CODING_AGENT_DIR")
        rows [{:label "auth.json" :value path}]]
    (when override
      (table.insert rows {:label "override" :value (.. "$" override)}))
    rows))

(fn provider-spec [provider name default-model auth-backend]
  (let [spec {}]
    (each [k v (pairs provider)] (tset spec k v))
    (set spec.name name)
    (set spec.default-model default-model)
    (set spec.auth-backend auth-backend)
    spec))

(extensions.unregister-by-owner :provider_openai_codex)
(local api (extensions.make-api :provider_openai_codex))

(api.register :auth-backend
              {:name :openai-codex
               :configured? codex-auth.configured?
               :get-fresh-creds! codex-auth.get-fresh-creds!
               :login! codex-login.login!
               :logout! codex-login.logout!
               :status-info auth-status-info})

(api.register :provider
              (provider-spec codex-responses :openai-codex :gpt-5.5
                             :openai-codex))

true
