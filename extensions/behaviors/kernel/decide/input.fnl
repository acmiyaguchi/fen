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
;;   handler; the answer lands on a later tick, and a confident follow-up
;;   still pending in steering moves to the follow-up queue (/decide undo
;;   moves it back), while a cancel only suggests ctrl-c.
;;
;; Behavior only; the pending topic token and the undo record live in the
;; non-reloadable `fen.extensions.decide.state`.

(local store (require :fen.extensions.decide.state))
(local service (require :fen.extensions.decide.service))
(local steering (require :fen.extensions.steering.service))
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
  {:topic_shift
   {:type :noul
    :instructions "Has the user moved to a topic unrelated to the recent conversation? Compare new_message with recent, the preceding conversation in order (oldest first)."
    :criteria {:true "new_message starts a task or subject unrelated to recent, so the earlier context would not help with it."
               :false "new_message continues, refines, follows up on, or relates to the work in recent."}}})

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
              (do (set prompts (+ prompts 1))
                  (set want-reply? true)
                  (table.insert entries 1 {:role :user :text (clip body DIGEST-ENTRY-BYTES)}))
              want-reply?
              (do (set want-reply? false)
                  (table.insert entries 1 {:role :assistant :text (clip body DIGEST-ENTRY-BYTES)})))))
      (set i (- i 1)))
    (values entries prompts)))

(fn ask-topic-shift! [api prompt token ctx]
  (let [(recent prompts) (recent-digest (or (?. ctx :state :agent :messages) []))]
    (when (>= prompts MIN-PRIOR-USER-TURNS)
      (service.ask-async!
        {:new_message (clip prompt NEW-MESSAGE-BYTES) : recent}
        SHIFT-QUESTIONS
        (fn [answers]
          (let [p (?. answers :topic_shift :noul)]
            (when (and (= store.topic-pending token)
                       (= (type p) :number)
                       (>= p SHIFT-THRESHOLD))
              (set store.topic-pending nil)
              (api.emit {:type :hint
                         :text SHIFT-HINT
                         :key (.. "handoff/topic-shift:"
                                  (text.utf8-prefix prompt HINT-KEY-BYTES))}))))))))

;; @doc fen.extensions.decide.input.forget-pending!
;; kind: function
;; signature: (forget-pending! ev) -> nil
;; summary: Drop the pending topic-shift token so a late answer for an older prompt never emits a hint; wired to :user and :reset-conversation.
;; tags: decide input hint
(fn M.forget-pending! [_ev]
  (set store.topic-pending nil))

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
                  piece (text.utf8-prefix (.. sep (text.utf8-prefix b.text left)) left)]
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
    (each [_ b (ipairs (or (?. last :content) [])) &until (>= used MAX-CONTEXT-BYTES)]
      (when (= b.type :tool-call)
        (let [name (tostring b.name)]
          (table.insert tools name)
          (set used (+ used (length name) 2)))))
    (if (and (= (?. last :role) :assistant) (> (length tools) 0))
        (text.utf8-prefix (.. "running tools: " (table.concat tools ", ")) MAX-CONTEXT-BYTES)
        (= (?. last :role) :tool-result)
        "reading tool results"
        "generating a response")))

(fn route-state [line runtime]
  (let [messages (or (?. runtime :agent :messages) [])]
    {:message (text.utf8-prefix line MAX-LINE-BYTES)
     :latest_user_message (latest-user-message messages)
     :activity (activity messages)}))

(fn apply-route! [api line runtime turn-id answers]
  (let [answer (?. answers :route)
        choice (when (and answer (= (type answer.confidence) :number)
                          (>= answer.confidence MIN-CONFIDENCE))
                 answer.choice)]
    ;; A decision about a finished turn is stale even if a new turn is running.
    (when (and (?. runtime :busy?) (= (?. runtime :turn-id) turn-id))
      (if (= choice :follow-up)
          (when (. (steering.requeue! line :steering :follow-up) :ok)
            (set store.reclassified line)
            (api.emit {:type :info
                       :text "reads as a follow-up, so it waits for this turn · /decide undo to steer now"}))
          (= choice :cancel)
          (api.emit {:type :info
                     :text "reads as a cancel request · ctrl-c cancels the turn"})))
    nil))

(fn steering-line? [input line ctx]
  "Whether steering will queue this input as a steering line: plain user input
   while busy that is neither a `>` follow-up nor slash text."
  (let [c (string.sub line 1 1)]
    (and (= (?. input :kind) :user-input)
         (?. ctx :busy?)
         (not= c ">")
         (not= c "/"))))

(fn classify-busy-line! [api line ctx]
  (let [runtime ctx.state
        turn-id (?. runtime :turn-id)]
    (service.ask-async!
      (route-state line runtime)
      ROUTE-QUESTIONS
      (fn [answers] (apply-route! api line runtime turn-id answers)))))

;; @doc fen.extensions.decide.input.undo!
;; kind: function
;; signature: (undo!) -> {:ok true :queued true :queue :steering}|{:ok false :error msg}
;; summary: Move the line last classified as a follow-up back to the steering queue while it is still pending there; backs /decide undo.
;; tags: decide input queue
(fn M.undo! []
  (let [line store.reclassified]
    (set store.reclassified nil)
    (if (= line nil)
        {:ok false :error "nothing to undo"}
        (steering.requeue! line :follow-up :steering))))

;; @doc fen.extensions.decide.input.on-status-info
;; kind: function
;; signature: (on-status-info ev) -> nil
;; summary: Drop the /decide undo record once a :set-status-info event reports an empty follow-up queue, as clear-queues! does for /cancel-all, /new, /resume, and /handoff.
;; tags: decide input queue
(fn M.on-status-info [ev]
  (when (= (?. ev :info :follow-up-queued) 0)
    (set store.reclassified nil)))

;; ---------------------------------------------------------------------------
;; Input handler
;; ---------------------------------------------------------------------------

;; @doc fen.extensions.decide.input.observe!
;; kind: function
;; signature: (observe! api input ctx) -> nil
;; summary: Observe one submitted line: an idle prompt starts a background topic-shift check, a plain busy line a background classification; nothing asks while decide is disabled, and the input is never changed.
;; tags: decide input
(fn M.observe! [api input ctx]
  (let [ctx (or ctx {})
        line (tostring (or (?. input :text) ""))
        token {}]
    ;; Any newer line makes an older topic-shift answer stale.
    (set store.topic-pending token)
    (when (service.enabled?)
      (if (not ctx.busy?)
          (ask-topic-shift! api line token ctx)
          (steering-line? input line ctx)
          (classify-busy-line! api line ctx))))
  nil)

M
