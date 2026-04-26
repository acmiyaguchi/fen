;; Provider registry and dispatcher.
;;
;; Mirrors pi-mono's `packages/ai/src/api-registry.ts`: keeps a map from API
;; identifier to the provider record, exposes a `complete` that routes by
;; api id. The agent loop holds a provider record (or just calls
;; `llm.complete`) and never imports a provider directly.
;;
;; Adding a provider: write a module under `src/providers/` that exports a
;; record with at minimum `{:api :provider :complete}`, then register it
;; here.

(local openai-completions (require :providers.openai_completions))

(local providers {})

(fn register [provider]
  (tset providers provider.api provider)
  provider)

(register openai-completions)

(fn get-provider [api]
  (or (. providers api)
      (error (.. "llm: unknown provider api: " (tostring api)))))

(fn complete [api model context options]
  "Dispatch a completion to the named provider. Returns a canonical
   AssistantMessage (see core.types)."
  (let [p (get-provider api)]
    (p.complete model context options)))

{: providers : register : get-provider : complete}
