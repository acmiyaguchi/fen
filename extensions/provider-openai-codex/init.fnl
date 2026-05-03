;; First-party OpenAI Codex subscription provider + auth backend extension.

(local extensions (require :fen.core.extensions))
(local codex-responses (require :fen.extensions.provider_openai_codex.openai_codex_responses))
(local codex-auth (require :fen.extensions.provider_openai_codex.openai_codex_oauth))

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
               :get-fresh-creds! codex-auth.get-fresh-creds!})

(api.register :provider
              (provider-spec codex-responses :openai-codex :gpt-5.5
                             :openai-codex))

true
