;; First-party OpenRouter provider extension.
;;
;; Registers provider `openrouter` (api `openrouter-completions`), an
;; OpenAI-Chat-Completions-compatible gateway authenticated by
;; OPENROUTER_API_KEY, with a curated tool-capable model list. models.json
;; providers declaring `"api": "openrouter-completions"` delegate here and
;; supply their own model list.

(local openrouter-completions (require :fen.extensions.provider_openrouter.openrouter_completions))

(fn provider-spec [provider name api-key-var]
  (let [spec {}]
    (each [k v (pairs provider)] (tset spec k v))
    (set spec.name name)
    (set spec.default-model (. provider.models 1 :id))
    (set spec.api-key-var api-key-var)
    spec))

(local M {})

(fn M.register [api]

;; @doc register-site:provider:openrouter
;; summary: OpenRouter Chat Completions provider using OPENROUTER_API_KEY and a curated tool-capable model list.
;; tags: provider openrouter completions
(api.register :provider
              (provider-spec openrouter-completions :openrouter
                             :OPENROUTER_API_KEY))

  true)

M
