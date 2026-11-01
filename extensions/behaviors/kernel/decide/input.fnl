;; Input-time questions for the decide service.
;;
;; decide registers one observing :input-handler (order 900, before the
;; steering fallback) that never changes or holds the input:
;;
;; - An idle prompt is checked for a shift to an unrelated topic; a likely
;;   shift emits a `topic changed · /handoff` :hint. Any later :user line or
;;   conversation reset makes a pending answer stale.
;; - A plain line typed while busy is classified as a correction, follow-up,
;;   or cancel request. Steering queues the line as usual right after this
;;   handler; the answer lands on a later tick. A confident follow-up only
;;   gets a hint (the line stays where it is), and a cancel only suggests
;;   ctrl-c.
;;
;; Behavior only; the pending idle tokens live in the
;; non-reloadable `fen.extensions.decide.state`.

(local store (require :fen.extensions.decide.state))
(local service (require :fen.extensions.decide.service))
(local text (require :fen.util.text))

(local M {})

(local trim text.trim)

;; Topic shift. A hint appears when P(unrelated topic) reaches
;; SHIFT-THRESHOLD; with fewer than MIN-PRIOR-USER-TURNS earlier prompts
;; there is no topic to drift from, so nothing is asked.
(local SHIFT-THRESHOLD 0.85)
(local MIN-PRIOR-USER-TURNS 2)
(local DIGEST-USER-TURNS 3)
(local DIGEST-ENTRY-BYTES 400)
(local NEW-MESSAGE-BYTES 1500)
(local HINT-KEY-BYTES 200)
(local SHIFT-HINT "topic changed · /handoff")
(local SHIFT-QUESTIONS
       {:topic_shift {:type :noul
                      :instructions "Has the user moved to a topic unrelated to the recent conversation? Compare new_message with recent, the preceding conversation in order (oldest first)."
                      :criteria {:true "new_message starts a task or subject unrelated to recent, so the earlier context would not help with it."
                                 :false "new_message continues, refines, follows up on, or relates to the work in recent."}}})

;; Durable preferences (#567).
(local PREFERENCE-THRESHOLD 0.85)
(local PREFERENCE-HINT "save as preference? · /prefer")
(local PREFERENCE-QUESTIONS
       {:durable_preference {:type :noul
                             :instructions "Did the user state a durable preference meant to apply beyond this task? Examine new_message."
                             :criteria {:true "new_message states a persistent rule, instruction, or preference intended to apply across sessions or future tasks (e.g. 'always use X', 'never do Y', 'from now on...')."
                                        :false "new_message gives task-specific instructions, queries, or corrections that apply only to the current task."}}})

;; Busy-line classification. Only a choice with at least MIN-CONFIDENCE acts.
(local MIN-CONFIDENCE 0.7)
(local MAX-LINE-BYTES 2000)
(local MAX-CONTEXT-BYTES 2000)
(local ROUTE-QUESTIONS
       {:route {:type :choice
                :instructions (.. "The user typed `message` while a coding agent was still "
                                  "working; `latest_user_message` is the user's most recent earlier message in "
                                  "that work and `activity` is the agent's latest step. "
                                  "Decide what the user wants done with `message`.")
                :criteria {:correction (.. "It corrects, redirects, or adds a constraint to the "
                                           "work in progress, so the agent should see it now.")
                           :follow-up (.. "It is a separate request or question that should wait "
                                          "until the current work finishes.")
                           :cancel "It asks the agent to stop or abandon the current work."}}})

;; ---------------------------------------------------------------------------
;; Topic shift (idle prompts)
;; ---------------------------------------------------------------------------

(fn content-text [content]
  "Text blocks of a message, concatenated."
  (if (= (type content) :string)
      content
      (= (type content) :table)
      (let [parts []]
        (each [_ block (ipairs content)]
          (when (and (= (?. block :type) :text) block.text)
            (table.insert parts block.text)))
        (table.concat parts ""))
      ""))

(fn clip [s n]
  (if (<= (length s) n) s (.. (text.utf8-prefix s n) "…")))

(fn recent-digest [messages]
  "Return the last few prompts, each with the reply that ended its turn, oldest
   first and clipped, plus how many prompts were found (at most DIGEST-USER-TURNS)."
  (let [entries []]
    (var prompts 0)
    (var want-reply? true)
    (var i (length messages))
    (while (and (>= i 1) (< prompts DIGEST-USER-TURNS))
      (let [m (. messages i)
            role (?. m :role)
            body (when (or (= role :user) (= role :assistant))
                   (trim (content-text m.content)))]
        (when (and body (not= body ""))
          (if (= role :user)
              (do
                (set prompts (+ prompts 1))
                (set want-reply? true)
                (table.insert entries 1
                              {:role :user
                               :text (clip body DIGEST-ENTRY-BYTES)}))
              want-reply?
              (do
                (set want-reply? false)
                (table.insert entries 1
                              {:role :assistant
                               :text (clip body DIGEST-ENTRY-BYTES)})))))
      (set i (- i 1)))
    (values entries prompts)))

(fn ask-idle! [api prompt token ctx]
  (let [(recent prompts) (recent-digest (or (?. ctx :state :agent :messages) []))
        questions {:durable_preference (. PREFERENCE-QUESTIONS
                                          :durable_preference)}]
    (when (>= prompts MIN-PRIOR-USER-TURNS)
      (tset questions :topic_shift (. SHIFT-QUESTIONS :topic_shift)))
    (service.ask-async! {:new_message (clip prompt NEW-MESSAGE-BYTES) : recent}
                        questions
                        (fn [answers]
                          (let [p-pref (?. answers :durable_preference :noul)
                                p-shift (?. answers :topic_shift :noul)]
                            (if (and (= store.preference-pending token)
                                     (= (type p-pref) :number)
                                     (>= p-pref PREFERENCE-THRESHOLD))
                                (do
                                  (set store.preference-pending nil)
                                  (set store.topic-pending nil)
                                  (api.emit {:type :hint
                                             :text PREFERENCE-HINT
                                             :key (.. "prefer/durable:"
                                                      (text.utf8-prefix prompt
                                                                        HINT-KEY-BYTES))
                                             :preference prompt}))
                                (and (= store.topic-pending token)
                                     (= (type p-shift) :number)
                                     (>= p-shift SHIFT-THRESHOLD))
                                (do
                                  (set store.topic-pending nil)
                                  (set store.preference-pending nil)
                                  (api.emit {:type :hint
                                             :text SHIFT-HINT
                                             :key (.. "handoff/topic-shift:"
                                                      (text.utf8-prefix prompt
                                                                        HINT-KEY-BYTES))}))))))))

;; @doc fen.extensions.decide.input.forget-pending!
;; kind: function
;; signature: (forget-pending! ev) -> nil
;; summary: Drop pending idle tokens so a late answer for an older prompt never emits a hint; wired to :user and :reset-conversation.
;; tags: decide input hint
(fn M.forget-pending! [_ev]
  (set store.topic-pending nil)
  (set store.preference-pending nil))

;; ---------------------------------------------------------------------------
;; Busy-line classification
;; ---------------------------------------------------------------------------

(fn capped-text [m limit]
  "Text of message m, at most limit bytes; stops collecting blocks at the cap
   so a huge message costs no more than the cap on the input path."
  (if (= (type m.content) :string)
      (text.utf8-prefix m.content limit)
      (let [parts []]
        (var left limit)
        (each [_ b (ipairs (or m.content [])) &until (<= left 0)]
          (when (and (= b.type :text) (= (type b.text) :string))
            (let [sep (if (> (length parts) 0) "\n" "")
                  piece (text.utf8-prefix (.. sep
                                              (text.utf8-prefix b.text left))
                                          left)]
              (table.insert parts piece)
              (set left (- left (length piece))))))
        (table.concat parts))))

(fn latest-user-message [messages]
  ;; Injected steering lines are ordinary user messages, so this is the most
  ;; recent user message, not necessarily the one that started the turn.
  (var found "")
  (for [i (length messages) 1 -1 &until (not= found "")]
    (let [m (. messages i)]
      (when (= m.role :user)
        (set found (capped-text m MAX-CONTEXT-BYTES)))))
  found)

(fn activity [messages]
  (let [last (. messages (length messages))
        tools []]
    ;; Bounded like the other fields: stop collecting names at the byte cap.
    (var used 0)
    (each [_ b (ipairs (or (?. last :content) []))
           &until (>= used MAX-CONTEXT-BYTES)]
      (when (= b.type :tool-call)
        (let [name (tostring b.name)]
          (table.insert tools name)
          (set used (+ used (length name) 2)))))
    (if (and (= (?. last :role) :assistant) (> (length tools) 0))
        (text.utf8-prefix (.. "running tools: " (table.concat tools ", "))
                          MAX-CONTEXT-BYTES)
        (= (?. last :role) :tool-result)
        "reading tool results"
        "generating a response")))

(fn route-state [line runtime]
  (let [messages (or (?. runtime :agent :messages) [])]
    {:message (text.utf8-prefix line MAX-LINE-BYTES)
     :latest_user_message (latest-user-message messages)
     :activity (activity messages)}))

(fn apply-route! [api _line runtime turn-id answers]
  (let [answer (?. answers :route)
        choice (when (and answer (= (type answer.confidence) :number)
                          (>= answer.confidence MIN-CONFIDENCE))
                 answer.choice)]
    ;; A decision about a finished turn is stale even if a new turn is running.
    (when (and (?. runtime :busy?) (= (?. runtime :turn-id) turn-id))
      (if (= choice :follow-up)
          ;; The mailbox never moves a queued line; the user decides.
          (api.emit {:type :info
                     :text "reads as a follow-up; prefix with `>` to queue it for after this turn"})
          (= choice :cancel)
          (api.emit {:type :info
                     :text "reads as a cancel request · ctrl-c cancels the turn"})))
    nil))

(fn steering-line? [input line ctx]
  "Whether steering will queue this input as a steering line: plain user input
   while busy that is neither a `>` follow-up nor slash text."
  (let [c (string.sub line 1 1)]
    (and (= (?. input :kind) :user-input) (?. ctx :busy?) (not= c ">")
         (not= c "/"))))

(fn classify-busy-line! [api line ctx]
  (let [runtime ctx.state
        turn-id (?. runtime :turn-id)]
    (service.ask-async! (route-state line runtime) ROUTE-QUESTIONS
                        (fn [answers]
                          (apply-route! api line runtime turn-id answers)))))

;; ---------------------------------------------------------------------------
;; Input handler
;; ---------------------------------------------------------------------------

;; @doc fen.extensions.decide.input.observe!
;; kind: function
;; signature: (observe! api input ctx) -> nil
;; summary: Observe one submitted line: an idle prompt starts a background preference and topic-shift check, a plain busy line a background classification; nothing asks while decide is disabled, and the input is never changed.
;; tags: decide input
(fn M.observe! [api input ctx]
  (let [ctx (or ctx {})
        line (tostring (or (?. input :text) ""))
        token {}]
    ;; Any newer line makes older idle answers stale.
    (set store.topic-pending token)
    (set store.preference-pending token)
    (when (service.enabled?)
      (if (not ctx.busy?) (ask-idle! api line token ctx)
          (steering-line? input line ctx) (classify-busy-line! api line ctx))))
  nil)

M
