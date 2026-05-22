;; Handoff extension.
;;
;; /handoff summarizes the current conversation, starts a fresh session, and
;; seeds it with the generated summary so the next turn can continue with a
;; compact context instead of the full transcript.

(local agent-mod (require :fen.core.agent))
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

(local trim (. (require :fen.util.text) :trim))

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

(fn reset-agent-session! [api state msgs ?last-saved]
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
  (api.session.set-info!
    (and state.session-info (state.session-info state.session)))
  (set state.flush (state.make-flush state.agent state.session (or ?last-saved 0)))
  (api.emit {:type :reset-conversation})
  (api.emit
    {:type :set-status-info
     :info {:provider state.opts.provider
            :model state.agent.model
            :thinking-status state.agent.thinking-status}}))

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

(fn summarize-for-handoff [agent direction ?yield!]
  (let [msgs []]
    (each [_ m (ipairs (or agent.messages []))]
      (table.insert msgs m))
    (table.insert msgs (types.user-message (handoff-prompt direction)))
    (let [asst (agent-mod.complete-messages agent msgs nil nil nil ?yield!)]
      (values (types.assistant-text asst) asst.usage))))

(fn handoff-message [summary]
  (types.user-message
    (.. "Handoff summary from the previous fen session. Use this as context and continue from it; do not ask me to restate it.\n\n"
        summary)))

(local CANCEL-MARKER {:type :handoff-cancel-marker})

(fn make-yield [state]
  "Yield to the presenter loop while the handoff completion is in flight."
  (fn []
    (coroutine.yield)
    (when state.cancel-requested?
      (error CANCEL-MARKER))))

(fn finish-handoff! [api state args]
  (api.emit {:type :llm-start})
  (let [(summary usage) (summarize-for-handoff state.agent args (make-yield state))
        msg (handoff-message summary)]
    (api.emit {:type :llm-end :usage usage})
    (reset-agent-session! api state [msg] 1)
    ;; Force the new transcript file into existence now;
    ;; make-flush starts at 1 so the seed is not duplicated
    ;; after the first assistant reply in the new session.
    (when (and state.session-backend state.session)
      (state.session-backend.append state.session msg))
    (api.emit {:type :user :text (content-text msg.content)})
    (api.emit
      {:type :assistant-text
       :text (.. "✓ Handoff complete. Started a new session seeded with:\n\n"
                 summary)})))

(fn start-handoff! [api state args]
  "Run /handoff as cooperative background work so the TUI can redraw and cancel."
  (set state.cancel-requested? false)
  (set state.turn
       (coroutine.create
         (fn []
           (let [(ok? err) (xpcall #(finish-handoff! api state args)
                                   #(if (= $1 CANCEL-MARKER)
                                      $1
                                      (debug.traceback (tostring $1) 2)))]
             (when (not ok?)
               (api.emit {:type :llm-end})
               (if (= err CANCEL-MARKER)
                   (api.emit {:type :cancelled})
                   (error err)))))))
  (set state.busy? true))

;; @doc fen.extensions.handoff.register!
;; kind: function
;; signature: (register!) -> true
;; summary: Register the /handoff command that summarizes the current session and seeds a fresh session with the result.
;; tags: handoff command session
(fn register! [api]
  (api.register :command
      {:name :handoff
       :order 27
       :description "Summarize this session, seed a fresh session with the summary"
       :idle-only? true
       :handler (fn [args state]
                  (if (= (length (or state.agent.messages [])) 0)
                      (api.emit {:type :error
                                        :error "nothing to hand off yet"})
                      (start-handoff! api state args)))} )
  true)

{:register register! :register! register!}
