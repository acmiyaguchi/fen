;; Provider dispatcher; :name is dispatch identity, :api is shared family metadata.

(local provider-registry (require :fen.core.extensions.register.provider))

;; @doc fen.core.llm.get-provider
;; kind: function
;; signature: (get-provider provider-name) -> provider
;; summary: Resolve a provider by registered :name. Errors if the name is unknown.
;; tags: provider llm
(fn get-provider [provider-name]
  (or (provider-registry.find provider-name)
      (error (.. "llm: unknown provider: " (tostring provider-name)))))

(fn complete [provider-name model context options ?on-event ?yield-fn]
  "Dispatch a completion to the named provider. Returns a canonical
   AssistantMessage (see core.types)."
  (let [p (get-provider provider-name)]
    (p.complete model context options ?on-event ?yield-fn)))

{: get-provider
 : complete}
