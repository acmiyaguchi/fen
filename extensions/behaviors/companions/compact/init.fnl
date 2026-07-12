;; Context compaction extension.
;;
;; /compact summarizes older messages in the current session, keeps recent
;; messages verbatim, and appends a :compaction entry so --continue rebuilds
;; the compacted context without replaying the old span.

(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))
(local tokens (require :fen.util.tokens))
(local coroutines (require :fen.util.coroutines))

(local DEFAULT-KEEP-RECENT-TOKENS 20000)
(local CANCEL-MARKER {:type :compact-cancel-marker})

(local BASE-COMPACT-PROMPT
  (table.concat
    ["Create a compact summary of the earlier part of this coding-agent session."
     ""
     "This summary will replace the old messages in the active model context."
     "Preserve facts needed to continue the current work."
     ""
     "Include:"
     "- the user's goal and current status"
     "- decisions already made"
     "- files inspected or changed, with paths"
     "- commands/tests run and their results"
     "- constraints, gotchas, and preferences"
     "- concrete next steps"
     ""
     "Write only the compact summary. Be concise but complete enough that the session can continue without the old messages."]
    "\n"))

(local trim (. (require :fen.util.text) :trim))

(fn tool-result [text is-error? ?details]
  (let [result {:content [(types.text-block text)]
                :is-error? (or is-error? false)}]
    (when ?details (set result.details ?details))
    result))

(fn compact-prompt [guidance]
  (let [guidance (trim guidance)]
    (if (= guidance "")
        BASE-COMPACT-PROMPT
        (table.concat
          [BASE-COMPACT-PROMPT
           ""
           "Additional user guidance for this compaction:"
           guidance]
          "\n"))))

(fn content-text [content]
  (if (= (type content) :string)
      content
      (= (type content) :table)
      (let [parts []]
        (each [_ block (ipairs content)]
          (when (= block.type :text)
            (table.insert parts (or block.text "")))
          (when (= block.type :thinking)
            (table.insert parts (or block.thinking "")))
          (when (= block.type :tool-call)
            (table.insert parts (.. "[tool-call " (tostring block.name) "]"))))
        (table.concat parts "\n"))
      ""))

(fn serialize-message [m]
  (.. (string.upper (tostring (or m.role :unknown))) ":\n"
      (content-text m.content)
      (if (= m.role :tool-result)
          (.. "\n[tool-result for " (tostring m.tool-name) "]")
          "")))

(fn message-tokens [m]
  (+ (tokens.approx-tokens m.role)
     (tokens.content-tokens m.content)
     (if (= m.role :tool-result)
         (tokens.approx-tokens m.tool-name)
         0)))

(fn messages-tokens [messages]
  (var n 0)
  (each [_ m (ipairs (or messages []))]
    (set n (+ n (message-tokens m))))
  n)

(fn assistant-has-tool-call? [m]
  (var found? false)
  (each [_ block (ipairs (or m.content []))]
    (when (= block.type :tool-call)
      (set found? true)))
  found?)

(fn safe-cut? [m]
  ;; V1 only cuts at user boundaries. Assistant-boundary cuts are tempting,
  ;; but can leave provider-specific thinking signatures or partial assistant
  ;; state at the head of the kept context after the older messages are
  ;; discarded.
  (= m.role :user))

(fn find-cut-point [messages keep-recent-tokens]
  "Return first kept message index, or nil if no useful safe cut exists."
  (let [n (length (or messages []))]
    (when (> n 2)
      (var recent 0)
      (var candidate nil)
      (var i n)
      (while (and (>= i 1) (not candidate))
        (set recent (+ recent (message-tokens (. messages i))))
        (when (> recent keep-recent-tokens)
          (set candidate (+ i 1)))
        (set i (- i 1)))
      (when candidate
        (var cut candidate)
        (while (and (<= cut n) (not (safe-cut? (. messages cut))))
          (set cut (+ cut 1)))
        (when (and (<= cut n) (> cut 1))
          cut)))))

(fn copy-slice [messages start stop]
  (let [out []]
    (for [i start stop]
      (table.insert out (. messages i)))
    out))

(fn summary-message [summary]
  (types.user-message
    (.. "Compaction summary of earlier fen session context. Use this as context for the continuing conversation; do not ask me to restate it.\n\n"
        summary)))

(fn prepare-compaction [agent keep-recent-tokens]
  (let [messages (or agent.messages [])
        cut (find-cut-point messages keep-recent-tokens)]
    (when cut
      (let [summarize (copy-slice messages 1 (- cut 1))
            kept (copy-slice messages cut (length messages))
            first-kept (. kept 1)]
        (when (and (> (length summarize) 0) first-kept)
          {:cut cut
           :summarize summarize
           :kept kept
           :first-kept first-kept
           :tokens-before (messages-tokens messages)})))))

(fn summarize [agent messages guidance ?yield!]
  (let [body []]
    (table.insert body (compact-prompt guidance))
    (table.insert body "")
    (table.insert body "Messages to summarize:")
    (each [i m (ipairs messages)]
      (table.insert body (.. "\n--- message " i " ---\n" (serialize-message m))))
    (let [asst (agent-mod.complete-messages
                 agent [(types.user-message (table.concat body "\n"))]
                 nil nil nil ?yield!)
          summary (types.assistant-text asst)]
      (when (= asst.stop-reason :error)
        (error (or asst.error-message summary "compaction model call failed")))
      (when (= (trim summary) "")
        (error "compaction model returned an empty summary"))
      (values summary asst.usage))))

(fn make-yield [state]
  (fn []
    (coroutine.yield)
    (when state.cancel-requested?
      (error CANCEL-MARKER))))

(fn replace-agent-messages! [agent msgs]
  (set agent.messages [])
  (each [_ m (ipairs msgs)]
    (table.insert agent.messages m)))

(fn compact-error [api message emit-error?]
  (when emit-error?
    (api.emit {:type :error :error message}))
  (values false message))

(fn finish-compact! [api run-state guidance trigger ?yield! ?emit-error?]
  (if (not (and run-state run-state.session-backend run-state.session
                    (. run-state.session-backend :append-entry)))
      (compact-error api "/compact requires a session backend with append-entry support" ?emit-error?)
      (let [plan (prepare-compaction run-state.agent DEFAULT-KEEP-RECENT-TOKENS)]
        (if (not plan)
            (compact-error api "not enough context to compact" ?emit-error?)
            (do
              ;; Flush before reading the kept message's entry id so any
              ;; in-memory messages appended since the last turn have stable
              ;; persisted identities. Validation failures above do not flush.
              (when run-state.flush (run-state.flush))
              (let [first-kept-entry-id (. plan.first-kept :__session-entry-id)]
                (if (not first-kept-entry-id)
                    (compact-error api "cannot compact: kept message has no session entry id" ?emit-error?)
                    (do
                      (api.emit {:type :llm-start})
                      (let [(summary usage) (summarize run-state.agent plan.summarize guidance ?yield!)
                            msg (summary-message summary)
                            new-messages []
                            append-entry (. run-state.session-backend :append-entry)]
                        (table.insert new-messages msg)
                        (each [_ m (ipairs plan.kept)]
                          (table.insert new-messages m))
                        (let [tokens-after (messages-tokens new-messages)
                              details {:summary summary
                                       :tokens-before plan.tokens-before
                                       :tokens-after tokens-after
                                       :messages-summarized (length plan.summarize)
                                       :messages-kept (length plan.kept)
                                       :guidance (trim guidance)
                                       :trigger trigger}
                              entry (append-entry
                                      run-state.session
                                      {:type :compaction
                                       :summary summary
                                       :first-kept-entry-id first-kept-entry-id
                                       :tokens-before plan.tokens-before
                                       :tokens-after tokens-after
                                       :guidance details.guidance
                                       :trigger trigger})]
                          (api.emit {:type :llm-end :usage usage})
                          (if entry
                              (do
                                (replace-agent-messages! run-state.agent new-messages)
                                (set run-state.flush
                                     (run-state.make-flush run-state.agent run-state.session
                                                           (length run-state.agent.messages)))
                                (let [event {}]
                                  (each [k v (pairs details)] (tset event k v))
                                  (set event.type :compaction-summary)
                                  (set event.agent run-state.agent)
                                  (api.emit event))
                                (api.emit {:type :set-status-info
                                           :info {:approx-context tokens-after}})
                                (values true details))
                              (compact-error api "failed to write compaction entry" ?emit-error?))))))))))))

(fn start-compact! [api run-state args]
  (set run-state.cancel-requested? false)
  (set run-state.turn
       (coroutines.create
         (fn []
           (let [(ok? err) (xpcall #(finish-compact! api run-state (trim args) :manual
                                                      (make-yield run-state) true)
                                   #(if (= $1 CANCEL-MARKER)
                                      $1
                                      (debug.traceback (tostring $1) 2)))]
             (when (not ok?)
               (api.emit {:type :llm-end :usage nil})
               (if (= err CANCEL-MARKER)
                   (api.emit {:type :cancelled})
                   (error err)))))))
  (set run-state.busy? true))

(fn execute-tool [api args ctx ?yield!]
  (let [run-state (?. ctx :state)
        guidance (trim (or (?. args :guidance) ""))]
    (var yield-error nil)
    (let [tool-yield! (when ?yield!
                        (fn []
                          (let [(ok? value) (pcall ?yield!)]
                            (when (not ok?)
                              (set yield-error value)
                              (error value)))))
          (ran? ok? value) (xpcall #(finish-compact! api run-state guidance :agent
                                                     tool-yield! false)
                                    (fn [err] err))]
      (if (not ran?)
          (do
            (api.emit {:type :llm-end :usage nil})
            ;; Cooperative cancellation must unwind to the agent loop so it
            ;; can append the canonical cancelled ToolResult and stop.
            (if (= ok? yield-error)
                (error ok?)
                (tool-result (.. "compaction failed: " (tostring ok?)) true)))
          ok?
          (tool-result
            (.. "Compacted context from ~" value.tokens-before
                " to ~" value.tokens-after " tokens.")
            false value)
          (tool-result value true)))))

(fn register! [api]
  (api.register :command
    {:name :compact
     :order 26
     :description "Summarize older context and keep recent messages in this session"
     :idle-only? true
     :handler (fn [args state]
                (start-compact! api state args))})
  (api.register :tool
    {:name :compact
     :label "Compact"
     :exposure :search
     :snippet "Summarize older context and keep recent messages"
     :description "Compact this session's model context when it is becoming too large. Summarizes older messages, keeps recent messages verbatim, and persists the compaction for session resume. Call only when substantial context can be discarded; do not call repeatedly or on short sessions."
     :parameters {:type :object
                  :properties {:guidance {:type :string
                                          :description "Optional instructions about facts, files, or progress the summary must preserve."}}}
     :execute (fn [args ctx ?yield!]
                (execute-tool api args ctx ?yield!))})
  true)

{:register register!
 :register! register!
 :_test {:find-cut-point find-cut-point
         :prepare-compaction prepare-compaction
         :messages-tokens messages-tokens
         :finish-compact! finish-compact!}}
