(local llm (require :core.llm))
(local tools-mod (require :core.tools))
(local log (require :util.log))

(fn make-agent [{: model : system : tools : api-key : on-event : max-tokens}]
  (let [messages (if system [{:role :system :content system}] [])
        tool-reg (or tools tools-mod.registry)]
    {: model
     : api-key
     :messages messages
     :tools tool-reg
     :max-tokens (or max-tokens 1024)
     :on-event (or on-event (fn [_] nil))}))

(fn emit [agent ev] (agent.on-event ev))

(fn assistant-text [msg]
  (or msg.content ""))

(fn run-tool-calls [agent tool-calls]
  (each [_ tc (ipairs tool-calls)]
    (let [name tc.function.name
          args tc.function.arguments
          _ (emit agent {:type :tool-call :name name :arguments args :id tc.id})
          result (tools-mod.execute agent.tools name args)]
      (emit agent {:type :tool-result :name name :result result :id tc.id})
      (table.insert agent.messages
                    {:role :tool
                     :tool_call_id tc.id
                     :content (or result.output "")}))))

(fn step [agent user-msg]
  (table.insert agent.messages {:role :user :content user-msg})
  (var done? false)
  (var final nil)
  (var safety 16)
  (while (and (not done?) (> safety 0))
    (set safety (- safety 1))
    (emit agent {:type :llm-start})
    (let [request (llm.build-request
                    {:model agent.model
                     :messages agent.messages
                     :tools (tools-mod.descriptors agent.tools)
                     :max-tokens agent.max-tokens})
          resp (llm.call-openai agent.api-key request)]
      (emit agent {:type :llm-end :usage resp.usage})
      (if (not resp.ok?)
          (do (emit agent {:type :error :error (or resp.error "unknown")})
              (set final (.. "[error] " (tostring (or resp.error "unknown"))))
              (set done? true))
          (let [msg resp.message]
            (table.insert agent.messages msg)
            (if (and (= resp.finish-reason :tool_calls) msg.tool_calls)
                (run-tool-calls agent msg.tool_calls)
                (do (let [text (assistant-text msg)]
                      (emit agent {:type :assistant-text :text text})
                      (set final text))
                    (set done? true)))))))
  (when (and (not done?) (<= safety 0))
    (log.warn "agent: hit step safety cap (16 turns)")
    (set final "[error] tool-call loop exceeded safety cap"))
  final)

{: make-agent : step}
