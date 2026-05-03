;; Handoff extension.
;;
;; /handoff summarizes the current conversation, starts a fresh session, and
;; seeds it with the generated summary so the next turn can continue with a
;; compact context instead of the full transcript.

(local extensions (require :fen.core.extensions))
(local llm (require :fen.core.llm))
(local types (require :fen.core.types))

(local OWNER :handoff)

(local BASE-HANDOFF-PROMPT
  (table.concat
    ["Create a handoff summary for continuing this coding-agent session in a new conversation."
     ""
     "Include:"
     "- the user's goal and current status"
     "- decisions already made"
     "- files changed or inspected, with paths"
     "- commands/tests run and their results"
     "- important constraints, gotchas, and next steps"
     ""
     "Write only the handoff. Be concise but complete enough that a new agent can continue without the old transcript."]
    "\n"))

(fn trim [s]
  (or (string.match (or s "") "^%s*(.-)%s*$") ""))

(fn handoff-prompt [direction]
  (let [direction (trim direction)]
    (if (= direction "")
        BASE-HANDOFF-PROMPT
        (table.concat
          [BASE-HANDOFF-PROMPT
           ""
           "Additional user direction for this handoff:"
           direction
           ""
           "Follow the additional direction when choosing emphasis, format, and level of detail."
           "Do not include this instruction text unless it is useful context for the next session."]
          "\n"))))

(fn install-agent-messages! [agent msgs]
  (set agent.messages [])
  (each [_ m (ipairs (or msgs []))]
    (table.insert agent.messages m)))

(fn reset-agent-session! [state msgs ?last-saved]
  "Replace the live agent with a fresh one, install msgs, and open a new transcript."
  (when state.close-session (state.close-session state.session))
  (set state.agent
       (state.make-agent-from-opts
         state.opts state.on-event state.agent-extra))
  (install-agent-messages! state.agent msgs)
  (set state.steering-queue [])
  (set state.follow-up-queue [])
  (when state.update-queue-status (state.update-queue-status))
  (set state.session (state.open-session state.opts))
  (extensions.set-session-info!
    (and state.session-info (state.session-info state.session)))
  (set state.flush (state.make-flush state.agent state.session (or ?last-saved 0)))
  (extensions.emit {:type :reset-conversation})
  (extensions.emit
    {:type :set-status-info
     :info {:provider state.opts.provider
            :model state.agent.model}}))

(fn content-text [content]
  (if (= (type content) :string)
      content
      (= (type content) :table)
      (let [parts []]
        (each [_ block (ipairs content)]
          (when (and (= (?. block :type) :text) block.text)
            (table.insert parts block.text)))
        (table.concat parts ""))
      ""))

(fn provider-options [agent]
  (let [opts {:api-key agent.api-key :max-tokens agent.max-tokens}]
    (each [k v (pairs (or agent.provider-options {}))]
      (tset opts k v))
    opts))

(fn summarize-for-handoff [agent direction]
  (let [msgs []]
    (each [_ m (ipairs (or agent.messages []))]
      (table.insert msgs m))
    (table.insert msgs (types.user-message (handoff-prompt direction)))
    (let [context {:system-prompt agent.system-prompt
                   :messages (agent.convert-to-llm msgs)
                   :tools []}
          asst (llm.complete agent.provider-name agent.model context
                             (provider-options agent))]
      (types.assistant-text asst))))

(fn handoff-message [summary]
  (types.user-message
    (.. "Handoff summary from the previous fen session. Use this as context and continue from it; do not ask me to restate it.\n\n"
        summary)))

(fn register! []
  (extensions.unregister-by-owner OWNER)
  (let [api (extensions.make-api OWNER)]
    (api.register :command
      {:name :handoff
       :order 27
       :description "Summarize this session, seed a fresh session with the summary"
       :idle-only? true
       :handler (fn [args state]
                  (if (= (length (or state.agent.messages [])) 0)
                      (extensions.emit {:type :error
                                        :error "nothing to hand off yet"})
                      (do
                        (extensions.emit {:type :llm-start})
                        (let [summary (summarize-for-handoff state.agent args)
                              msg (handoff-message summary)]
                          (extensions.emit {:type :llm-end})
                          (reset-agent-session! state [msg] 1)
                          ;; Force the new transcript file into existence now;
                          ;; make-flush starts at 1 so the seed is not duplicated
                          ;; after the first assistant reply in the new session.
                          (when (and state.session-backend state.session)
                            (state.session-backend.append state.session msg))
                          (extensions.emit {:type :user :text (content-text msg.content)})
                          (extensions.emit
                            {:type :assistant-text
                             :text (.. "✓ Handoff complete. Started a new session seeded with:\n\n"
                                       summary)})))))}))
  true)

(register!)

{:register! register!}
