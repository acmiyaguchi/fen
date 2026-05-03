;; First-party OpenAI provider extension.

(local extensions (require :fen.core.extensions))
(local openai-completions (require :fen.extensions.provider_openai.openai_completions))
(local openai-responses (require :fen.extensions.provider_openai.openai_responses))

(fn provider-spec [provider name default-model api-key-var]
  (let [spec {}]
    (each [k v (pairs provider)] (tset spec k v))
    (set spec.name name)
    (set spec.default-model default-model)
    (set spec.api-key-var api-key-var)
    spec))

(extensions.unregister-by-owner :provider_openai)
(local api (extensions.make-api :provider_openai))

(api.register :provider
              (provider-spec openai-completions :openai :gpt-5.4-nano
                             :OPENAI_API_KEY))
(api.register :provider
              (provider-spec openai-responses :openai-responses :gpt-5.4-nano
                             :OPENAI_API_KEY))

true
