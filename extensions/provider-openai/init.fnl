;; First-party OpenAI provider extension.

(local ext-api (require :fen.core.extensions.api))
(local openai-completions (require :fen.extensions.provider_openai.openai_completions))
(local openai-responses (require :fen.extensions.provider_openai.openai_responses))

(fn provider-spec [provider name default-model api-key-var]
  (let [spec {}]
    (each [k v (pairs provider)] (tset spec k v))
    (set spec.name name)
    (set spec.default-model default-model)
    (set spec.api-key-var api-key-var)
    spec))

(local api (ext-api.make-api :provider_openai))

;; @doc register-site:provider:openai
;; summary: OpenAI Chat Completions provider using OPENAI_API_KEY and the default gpt-5.4-nano model.
;; tags: provider openai completions
(api.register :provider
              (provider-spec openai-completions :openai :gpt-5.4-nano
                             :OPENAI_API_KEY))
;; @doc register-site:provider:openai-responses
;; summary: OpenAI Responses API provider using OPENAI_API_KEY and the default gpt-5.4-nano model.
;; tags: provider openai responses
(api.register :provider
              (provider-spec openai-responses :openai-responses :gpt-5.4-nano
                             :OPENAI_API_KEY))

true
