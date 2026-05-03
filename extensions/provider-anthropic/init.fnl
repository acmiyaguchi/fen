;; First-party Anthropic provider extension.

(local extensions (require :fen.core.extensions))
(local anthropic-messages (require :fen.extensions.provider_anthropic.anthropic_messages))

(fn provider-spec [provider name default-model api-key-var]
  (let [spec {}]
    (each [k v (pairs provider)] (tset spec k v))
    (set spec.name name)
    (set spec.default-model default-model)
    (set spec.api-key-var api-key-var)
    spec))

(extensions.unregister-by-owner :provider_anthropic)
(local api (extensions.make-api :provider_anthropic))

(api.register :provider
              (provider-spec anthropic-messages :anthropic :claude-haiku-4-5
                             :ANTHROPIC_API_KEY))

true
