;; Agent loop. Operates entirely on canonical AgentMessages (see core.types);
;; provider-specific conversion is delegated to whichever provider record is
;; selected via `:provider-api`.
;;
;; Mirrors pi-mono's split: the agent loop owns the prompt → assistant →
;; tool-calls → tool-results → loop control. Wire shaping, auth, and HTTP
;; transport live in src/providers/*.

(local llm (require :core.llm))
(local tools-mod (require :core.tools))
(local types (require :core.types))
(local log (require :util.log))

(local SAFETY-CAP 16)

(fn make-agent [{: provider-api : model : system : tools : api-key : on-event
                 : max-tokens : convert-to-llm}]
  (let [tool-list (or tools tools-mod.registry)]
    {:provider-api (or provider-api :openai-completions)
     : model
     : api-key
     :system-prompt system
     :messages []
     :tools tool-list
     :max-tokens (or max-tokens 1024)
     :on-event (or on-event (fn [_] nil))
     ;; Mirrors pi-mono's `convertToLlm`: AgentMessage[] → canonical Message[].
     ;; The provider's convert-messages then turns canonical Messages into
     ;; wire shape. Default is identity — agent.messages already holds
     ;; canonical Messages; this seam is here for future custom AgentMessage
     ;; extensions (notes, internal markers, etc.).
     :convert-to-llm (or convert-to-llm (fn [msgs] msgs))}))

(fn emit [agent ev] (agent.on-event ev))

(fn build-context [agent]
  {:system-prompt agent.system-prompt
   :messages (agent.convert-to-llm agent.messages)
   :tools (tools-mod.descriptors agent.tools)})

(fn run-tool-calls [agent tool-calls]
  "Execute the tool-call blocks of the latest assistant turn; append a
   canonical ToolResultMessage for each."
  (each [_ tc (ipairs tool-calls)]
    (emit agent {:type :tool-call
                 :name tc.name
                 :arguments tc.arguments
                 :id tc.id})
    (let [result (tools-mod.execute agent.tools tc.name tc.arguments)
          msg (types.tool-result-message
                {:tool-call-id tc.id
                 :tool-name tc.name
                 :content result.content
                 :is-error? result.is-error?
                 :details result.details})]
      (table.insert agent.messages msg)
      (emit agent {:type :tool-result
                   :name tc.name
                   :id tc.id
                   :result result}))))

(fn step [agent user-msg]
  "Run one user turn through the loop. Appends a UserMessage, then iterates
   provider call → tool execution until the assistant returns a non-tool
   stop reason or we hit the safety cap. Returns the final visible text."
  (table.insert agent.messages (types.user-message user-msg))
  (var done? false)
  (var final nil)
  (var safety SAFETY-CAP)
  (while (and (not done?) (> safety 0))
    (set safety (- safety 1))
    (emit agent {:type :llm-start})
    (let [context (build-context agent)
          asst (llm.complete agent.provider-api agent.model context
                             {:api-key agent.api-key
                              :max-tokens agent.max-tokens})]
      (emit agent {:type :llm-end :usage asst.usage})
      (table.insert agent.messages asst)
      (if (= asst.stop-reason :error)
          (let [err-text (or asst.error-message "unknown")]
            (emit agent {:type :error :error err-text})
            (set final (.. "[error] " err-text))
            (set done? true))
          (= asst.stop-reason :tool-use)
          (run-tool-calls agent (types.assistant-tool-calls asst))
          ;; :stop / :length / :aborted → final
          (let [text (types.assistant-text asst)]
            (emit agent {:type :assistant-text :text text})
            (set final text)
            (set done? true)))))
  (when (and (not done?) (<= safety 0))
    (log.warn (.. "agent: hit step safety cap (" SAFETY-CAP " turns)"))
    (set final "[error] tool-call loop exceeded safety cap"))
  final)

{: make-agent : step : SAFETY-CAP}
