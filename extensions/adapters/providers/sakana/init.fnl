;; First-party Sakana AI provider extension.
;;
;; Registers provider `sakana`, an OpenAI-Responses-compatible endpoint
;; authenticated by SAKANA_API_KEY. The Fugu models are reasoning models with a
;; 1M-token context window; max-output values are Sakana's conservative
;; defaults (not published in its catalog), mirroring pi-mono's
;; `pi-sakana-provider`.

(local sakana-responses (require :fen.extensions.provider_sakana.sakana_responses))

;; Sakana's published model catalog. Order matters: the first entry is the
;; provider default when no `--model` / saved model is given.
(local MODELS
  [{:id :fugu-ultra}
   {:id :fugu}
   {:id :fugu-ultra-20260615}])

(fn provider-spec [provider name default-model api-key-var models]
  (let [spec {}]
    (each [k v (pairs provider)] (tset spec k v))
    (set spec.name name)
    (set spec.default-model default-model)
    (set spec.api-key-var api-key-var)
    (set spec.models models)
    spec))

(local M {})

(fn M.register [api]

;; @doc register-site:provider:sakana
;; summary: Sakana AI Responses provider using SAKANA_API_KEY and the default fugu-ultra model.
;; tags: provider sakana responses
(api.register :provider
              (provider-spec sakana-responses :sakana :fugu-ultra
                             :SAKANA_API_KEY MODELS))

  true)

M
