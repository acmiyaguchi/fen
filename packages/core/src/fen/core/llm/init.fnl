;; Provider dispatcher.
;;
;; Providers are contributed through the extension registry with
;; `api.register :provider`. The agent loop passes a provider api/name to
;; `complete`; this module resolves the registered provider record and invokes
;; its `:complete` method.

(local extensions (require :fen.core.extensions))

(fn register [provider]
  "Compatibility helper for in-process callers/tests. Prefer
   `(extensions.register :provider provider owner)`."
  (extensions.register :provider provider :llm)
  provider)

(fn get-provider [api]
  (or (extensions.find-provider api)
      (error (.. "llm: unknown provider api: " (tostring api)))))

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

(fn complete [api model context options ?on-event ?yield-fn]
  "Dispatch a completion to the named provider. Returns a canonical
   AssistantMessage (see core.types)."
  (let [p (get-provider api)]
    (p.complete model context options ?on-event ?yield-fn)))

{: register
 : get-provider
 : complete
 : emit-block-events}
