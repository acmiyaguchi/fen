;; Provider dispatcher.
;;
;; Providers are contributed through the extension registry with
;; `api.register :provider`. Provider :name is the unique dispatch identity;
;; provider :api is protocol/family metadata and may be shared by many
;; providers (for example openai-compatible local/proxy endpoints).

(local extensions (require :fen.core.extensions))

;; @doc fen.core.llm.register
;; kind: function
;; signature: (register provider) -> provider
;; summary: Compatibility helper for in-process callers/tests. Prefer (extensions.register :provider provider owner) in extensions.
;; tags: provider llm
(fn register [provider]
  "Compatibility helper for in-process callers/tests. Prefer
   `(extensions.register :provider provider owner)`."
  (extensions.register :provider provider :llm)
  provider)

;; @doc fen.core.llm.get-provider
;; kind: function
;; signature: (get-provider provider-name) -> provider
;; summary: Resolve a provider by registered :name. Errors if the name is unknown.
;; tags: provider llm
(fn get-provider [provider-name]
  (or (extensions.find-provider provider-name)
      (error (.. "llm: unknown provider: " (tostring provider-name)))))

;; @doc fen.core.llm.emit-block-events
;; kind: function
;; signature: (emit-block-events asst emit) -> nil
;; summary: Synthesize streaming block events from a complete AssistantMessage. Compatibility bridge for providers that do not implement :complete-stream natively.
;; tags: provider llm streaming
(fn emit-block-events [asst emit]
  "Synthesize streaming block events from an already-complete AssistantMessage.
   The compatibility bridge for providers that have not implemented
   :complete-stream yet."
  (when emit
    (emit {:type :start})
    ;; Error assistant messages often carry a synthetic "[error] ..." text
    ;; block for final-message consumers. Do not replay that block as normal
    ;; assistant text in the stream fallback; emit only the terminal error.
    (when (not= asst.stop-reason :error)
      (each [i block (ipairs (or asst.content []))]
        (if (= block.type :text)
            (let [text (or block.text "")]
              (emit {:type :text-start :content-index i})
              (when (not= text "")
                (emit {:type :text-delta :content-index i :delta text}))
              (emit {:type :text-end :content-index i :content text}))
            (= block.type :thinking)
            (let [text (or block.thinking "")]
              (emit {:type :thinking-start :content-index i})
              (when (not= text "")
                (emit {:type :thinking-delta :content-index i :delta text}))
              (emit {:type :thinking-end :content-index i :content text}))
            (= block.type :tool-call)
            (do
              (emit {:type :tool-call-start :content-index i})
              (emit {:type :tool-call-end :content-index i :tool-call block})))))
    (emit (if (= asst.stop-reason :error)
              {:type :error :message asst}
              {:type :done :message asst}))))

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
 : complete
 : emit-block-events}
