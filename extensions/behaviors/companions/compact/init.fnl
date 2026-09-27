;; Context compaction extension.
;;
;; /compact summarizes older messages in the current session, keeps recent
;; messages verbatim, and appends a :compaction entry so --continue rebuilds
;; the compacted context without replaying the old span.
;;
;; When the opt-in `decide` extension is enabled, older tool results that Jev
;; rates as no longer needed reach the summarizer as one-line stubs. The
;; rating is advisory: any decide failure summarizes the span as before.
;;
;; Auto-compaction is opt-in through `extensions.compact.autoCompactTokens`.
;; Each completed turn is evaluated once, on the next idle :runtime-tick, so
;; only ticking presenters compact and a turn another handler starts right
;; away (a goal iteration, a queued follow-up) is never delayed. Inside the
;; soft window below the threshold, decide picks whether this is a good moment.

(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))
(local tokens (require :fen.util.tokens))
(local coroutines (require :fen.util.coroutines))
(local json (require :fen.util.json))
(local text (require :fen.util.text))
(local decide (require :fen.extensions.decide.service))
(local ext-state (require :fen.core.extensions.state))

(local DEFAULT-KEEP-RECENT-TOKENS 20000)
(local CANCEL-MARKER {:type :compact-cancel-marker})

;; Tool-result rating (decide). A result is stubbed when P(no longer needed)
;; reaches DROP-THRESHOLD; results smaller than MIN-RATED-BYTES are not worth
;; a question. Jev sees each result as a head+tail excerpt.
(local DROP-THRESHOLD 0.8)
(local MIN-RATED-BYTES 1024)
(local RATE-HEAD-BYTES 1500)
(local RATE-TAIL-BYTES 500)
(local REQUEST-HEAD-BYTES 1500)
(local REQUEST-TAIL-BYTES 500)
(local ARGS-SUMMARY-BYTES 120)
;; Headroom under decide's request cap for the request envelope around the measured entries.
(local BATCH-BUDGET-RATIO 0.8)
(local DROP-CRITERIA
  {:true "The continuing work does not need this output: it is superseded, redundant, or unrelated to the current request."
   :false "The output holds facts the continuing work still needs, such as file contents, errors, test results, or decisions."})

;; Auto-compaction. The soft window is [ratio * threshold, threshold); inside
;; it decide must rate the moment at least GOOD-MOMENT-THRESHOLD.
(local SOFT-WINDOW-RATIO 0.8)
(local GOOD-MOMENT-THRESHOLD 0.7)
(local MOMENT-MESSAGES 6)
(local MOMENT-TAIL-BYTES 400)
(local MOMENT-QUESTION
  {:type :noul
   :instructions "state.recent_messages are the latest messages of a coding-agent session, oldest first, each cut to its tail. Is this a good moment to compact: the last subtask finished (e.g. checks passed) rather than work being mid-flight (an edit awaiting validation, a failing check being iterated)?"
   :criteria {:true "The last subtask finished: checks passed or the assistant reported the work done, and nothing awaits validation."
              :false "Work is mid-flight: an edit awaits validation, a failing check is being iterated, or the assistant announced an immediate next step."}})

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

(fn utf8-suffix [s n]
  "Last n bytes of s, advanced past any split UTF-8 continuation bytes."
  (var i (math.max 1 (+ (- (length s) n) 1)))
  (while (and (<= i (length s))
              (let [b (string.byte s i)] (and (>= b 0x80) (< b 0xC0))))
    (set i (+ i 1)))
  (string.sub s i))

(fn head-tail [s head tail]
  (if (<= (length s) (+ head tail))
      s
      (let [h (text.utf8-prefix s head)
            t (utf8-suffix s tail)]
        (.. h "\n[... " (- (length s) (length h) (length t)) " bytes omitted ...]\n" t))))

(fn latest-user-text [messages]
  (var found nil)
  (var i (length messages))
  (while (and (>= i 1) (not found))
    (let [m (. messages i)]
      (when (= m.role :user)
        (set found (content-text m.content))))
    (set i (- i 1)))
  (or found ""))

(fn tool-call-args [messages]
  (let [out {}]
    (each [_ m (ipairs messages)]
      (when (= m.role :assistant)
        (each [_ block (ipairs (or m.content []))]
          (when (and (= block.type :tool-call) block.id)
            (tset out block.id block.arguments)))))
    out))

(fn args-summary [args]
  (when (and (= (type args) :table) (not= (next args) nil))
    (let [(ok? s) (pcall json.encode args)]
      (when ok?
        (if (<= (length s) ARGS-SUMMARY-BYTES)
            s
            (.. (text.utf8-prefix s ARGS-SUMMARY-BYTES) "…"))))))

(fn rating-candidates [span]
  (let [args-by-id (tool-call-args span)
        out []]
    (each [i m (ipairs span)]
      (when (= m.role :tool-result)
        (let [body (content-text m.content)
              args (args-summary (. args-by-id m.tool-call-id))]
          (when (>= (length body) MIN-RATED-BYTES)
            (table.insert out {:id (.. "r" i)
                               :index i
                               :bytes (length body)
                               : args
                               :item {:tool (tostring m.tool-name)
                                      : args
                                      :bytes (length body)
                                      :is_error (= m.is-error? true)
                                      :output (head-tail body RATE-HEAD-BYTES RATE-TAIL-BYTES)}})))))
    out))

(fn drop-question [id]
  {:type :noul
   :instructions (.. "state.tool_results." id " is an older tool result from a coding-agent session about to be summarized. Is it no longer needed to continue the work on state.request?")
   :criteria DROP-CRITERIA})

(fn encoded-bytes [v]
  (let [(ok? s) (pcall json.encode v)]
    (if ok? (length s) math.huge)))

(fn rating-batches [request candidates]
  "Group candidates into requests that fit decide's size guard; a candidate
   too large on its own is left unrated."
  (let [budget (- (* decide.max-request-bytes BATCH-BUDGET-RATIO)
                  (encoded-bytes request))
        batches []]
    (var current nil)
    (var used 0)
    (each [_ c (ipairs candidates)]
      (let [cost (+ (encoded-bytes c.item) (encoded-bytes (drop-question c.id)))]
        (when (<= cost budget)
          (when (or (not current) (> (+ used cost) budget))
            (set current {:state {: request :tool_results {}} :questions {}})
            (set used 0)
            (table.insert batches current))
          (tset current.state.tool_results c.id c.item)
          (tset current.questions c.id (drop-question c.id))
          (set used (+ used cost)))))
    batches))

(fn stub-message [m c]
  (let [out {}]
    (each [k v (pairs m)] (tset out k v))
    (set out.content
         [(types.text-block
            (.. "[tool result omitted before compaction: " (tostring m.tool-name)
                (if c.args (.. " " c.args) "")
                ", " c.bytes " bytes]"))])
    out))

(fn rate-tool-results [messages span ?yield!]
  "Return the span to summarize and how many tool results were stubbed.
   Stubs replace entries in a copy only; `messages` and `span` stay intact.
   Errors raised by ?yield! (cancellation) propagate through decide."
  (let [candidates (if (decide.enabled?) (rating-candidates span) [])]
    (if (= (length candidates) 0)
        (values span 0)
        (let [request (head-tail (latest-user-text messages) REQUEST-HEAD-BYTES REQUEST-TAIL-BYTES)
              drop {}]
          (each [_ batch (ipairs (rating-batches request candidates))]
            (let [answers (decide.ask batch.state batch.questions {:yield ?yield!})]
              (when answers
                (each [id _ (pairs batch.questions)]
                  (let [p (?. answers id :noul)]
                    (when (and (= (type p) :number) (>= p DROP-THRESHOLD))
                      (tset drop id true)))))))
          (let [out []]
            (var n 0)
            (each [_ m (ipairs span)] (table.insert out m))
            (each [_ c (ipairs candidates)]
              (when (. drop c.id)
                (tset out c.index (stub-message (. span c.index) c))
                (set n (+ n 1))))
            (values out n))))))

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
                      (let [(span dropped) (rate-tool-results run-state.agent.messages
                                                              plan.summarize ?yield!)
                            (summary usage) (summarize run-state.agent span guidance ?yield!)
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
                                       :tool-results-dropped dropped
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

(fn start-compact! [api run-state args trigger]
  (set run-state.cancel-requested? false)
  (set run-state.turn
       (coroutines.create
         (fn []
           (let [(ok? err) (xpcall #(finish-compact! api run-state (trim args) trigger
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

;; Per-instance auto-compaction bookkeeping; a reload starts fresh.
;; pending: the last completed turn awaiting evaluation on the next tick.
;; evaluated: the last turn evaluated, so a compaction's own completion (same
;; agent and turn id) is never evaluated again and failures cannot loop.
(local auto {:pending nil :evaluated nil})

(fn auto-threshold [api]
  (let [(ok? s) (pcall api.settings.extension)
        n (when (and ok? (= (type s) :table)) s.autoCompactTokens)]
    (when (and (= (type n) :number) (> n 0))
      n)))

(fn idle? [st]
  (and (not st.busy?) (not st.turn)))

(fn same-turn? [a b]
  (and (= a.agent b.agent) (= a.turn-id b.turn-id)))

(fn compact-loaded? []
  (= (?. ext-state.extensions :compact :status) :loaded))

(fn auto-position [api st]
  "Return (tokens threshold) when st's context reaches the soft window and can
   be compacted; nil when auto-compaction is off or there is nothing to do."
  (let [threshold (auto-threshold api)
        agent st.agent]
    (when (and threshold agent)
      (let [n (messages-tokens agent.messages)]
        (when (and (>= n (* SOFT-WINDOW-RATIO threshold))
                   st.session
                   (?. st :session-backend :append-entry)
                   (prepare-compaction agent DEFAULT-KEEP-RECENT-TOKENS))
          (values n threshold))))))

(fn tail-text [s]
  (if (<= (length s) MOMENT-TAIL-BYTES)
      s
      (.. "…" (utf8-suffix s MOMENT-TAIL-BYTES))))

(fn moment-state [messages]
  "The last few messages as role plus the tail of their text; tool results
   also name the tool and whether it failed."
  (let [n (length messages)
        out []]
    (for [i (math.max 1 (+ (- n MOMENT-MESSAGES) 1)) n]
      (let [m (. messages i)
            entry {:role (tostring m.role) :text (tail-text (content-text m.content))}]
        (when (= m.role :tool-result)
          (set entry.tool (tostring m.tool-name))
          (set entry.is_error (= m.is-error? true)))
        (table.insert out entry)))
    {:recent_messages out}))

(fn start-auto! [api st notice]
  (api.emit {:type :info :text notice})
  (start-compact! api st "" :auto))

(fn on-moment-answer [api st key answers]
  (let [p (?. answers :good_moment :noul)]
    (when (and (= (type p) :number) (>= p GOOD-MOMENT-THRESHOLD)
               (compact-loaded?) (idle? st) (same-turn? st key))
      (let [(n threshold) (auto-position api st)]
        (when (and n (< n threshold))
          (start-auto! api st (.. "compact: good moment at ~" (tokens.fmt-tokens n)
                                  " of " (tokens.fmt-tokens threshold)
                                  " tokens; compacting early")))))))

(fn evaluate-turn! [api st key]
  (when (not (and auto.evaluated (same-turn? auto.evaluated key)))
    (set auto.evaluated key)
    (let [(n threshold) (auto-position api st)]
      (if (not n)
          nil
          (>= n threshold)
          (start-auto! api st (.. "compact: context ~" (tokens.fmt-tokens n)
                                  " reached autoCompactTokens " (tokens.fmt-tokens threshold)
                                  "; compacting"))
          (decide.enabled?)
          (decide.ask-async! (moment-state st.agent.messages)
                             {:good_moment MOMENT-QUESTION}
                             (fn [answers] (on-moment-answer api st key answers)))))))

(fn on-turn-complete [ev]
  ;; A deliberate cancel is not a moment to start background model work.
  (when (and ev.state (not= ev.status :cancelled))
    (set auto.pending {:state ev.state :agent ev.agent :turn-id ev.turn-id})))

(fn on-runtime-tick [api]
  (let [p auto.pending]
    (when p
      (set auto.pending nil)
      (when (and (idle? p.state) (same-turn? p.state p))
        (evaluate-turn! api p.state p)))))

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
                (start-compact! api state args :manual))})
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
  (api.on :agent-turn-complete on-turn-complete)
  (api.on :runtime-tick (fn [_ev] (on-runtime-tick api)))
  true)

{:register register!
 :register! register!
 :_test {:find-cut-point find-cut-point
         :prepare-compaction prepare-compaction
         :messages-tokens messages-tokens
         :finish-compact! finish-compact!}}
