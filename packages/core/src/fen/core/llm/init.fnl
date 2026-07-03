;; Provider dispatcher.
;;
;; Providers are contributed through the extension registry with
;; `api.register :provider`. Provider :name is the unique dispatch identity;
;; provider :api is protocol/family metadata and may be shared by many
;; providers (for example openai-compatible local/proxy endpoints).

(local register-registry (require :fen.core.extensions.register))
(local provider-registry (require :fen.core.extensions.register.provider))

;; @doc fen.core.llm.register
;; kind: function
;; signature: (register provider) -> provider
;; summary: Compatibility helper for in-process callers/tests. Prefer (extensions.register :provider provider owner) in extensions.
;; tags: provider llm
(fn register [provider]
  "Compatibility helper for in-process callers/tests. Prefer
   `(extensions.register :provider provider owner)`."
  (register-registry.register :provider provider :llm)
  provider)

;; @doc fen.core.llm.get-provider
;; kind: function
;; signature: (get-provider provider-name) -> provider
;; summary: Resolve a provider by registered :name. Errors if the name is unknown.
;; tags: provider llm
(fn get-provider [provider-name]
  (or (provider-registry.find provider-name)
      (error (.. "llm: unknown provider: " (tostring provider-name)))))

;; @doc fen.core.llm.complete
;; kind: function
;; signature: (complete provider-name model context options ?on-event ?yield-fn) -> AssistantMessage
;; summary: Dispatch a completion to the named provider. Returns a canonical AssistantMessage. The provider chooses native streaming, cooperative-yield streaming, or blocking based on which callbacks are present.
;; tags: provider llm
(fn complete [provider-name model context options ?on-event ?yield-fn]
  "Dispatch a completion to the named provider. Returns a canonical
   AssistantMessage (see core.types)."
  (let [p (get-provider provider-name)]
    (p.complete model context options ?on-event ?yield-fn)))

{: register
 : get-provider
 : complete}
