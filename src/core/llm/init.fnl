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
(local openai-responses (require :providers.openai_responses))
(local openai-codex-responses (require :providers.openai_codex_responses))
(local anthropic-messages (require :providers.anthropic_messages))

(local providers {})

(fn register [provider]
  (tset providers provider.api provider)
  provider)

(register openai-completions)
(register openai-responses)
(register openai-codex-responses)
(register anthropic-messages)

(fn get-provider [api]
  (or (. providers api)
      (error (.. "llm: unknown provider api: " (tostring api)))))

(fn complete [api model context options]
  "Dispatch a completion to the named provider. Returns a canonical
   AssistantMessage (see core.types)."
  (let [p (get-provider api)]
    (p.complete model context options)))

(fn cooperative-complete [p model context options yield-fn]
  "Try p.complete-coop, fall back to blocking p.complete. Shared by
   complete-coop and complete-stream's fallback adapter."
  (if p.complete-coop
      (p.complete-coop model context options yield-fn)
      (p.complete model context options)))

(fn complete-coop [api model context options yield-fn]
  "Dispatch a cooperative completion when the provider implements one.
   Providers without :complete-coop fall back to blocking :complete, so they
   remain correct but will still freeze the interactive TUI during HTTP."
  (cooperative-complete (get-provider api) model context options yield-fn))

(fn emit-block-events [asst emit]
  "Synthesize streaming block events from an already-complete AssistantMessage.
   This is the compatibility bridge for providers that have not implemented
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

(fn complete-stream [api model context options on-event yield-fn]
  "Dispatch a streaming completion.

   Native streaming providers should emit AssistantMessageEvent-like tables to
   `on-event` and return the final canonical AssistantMessage. Providers that
   have not migrated yet are adapted by calling complete-coop/complete and
   synthesizing start/block/done events from the final message."
  (let [p (get-provider api)]
    (if p.complete-stream
        (p.complete-stream model context options on-event yield-fn)
        (let [asst (cooperative-complete p model context options yield-fn)]
          (emit-block-events asst on-event)
          asst))))

{: providers
 : register
 : get-provider
 : complete
 : complete-coop
 : complete-stream
 : emit-block-events}
