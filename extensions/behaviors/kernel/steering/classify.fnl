;; Advisory classifier for plain lines submitted while a turn is busy.
;;
;; The line is already in the steering queue when classification starts, so
;; it never delays input. When the opt-in decide service answers with enough
;; confidence, a follow-up still pending in steering moves to the follow-up
;; queue, and a cancel request only suggests the cancel key. Anything else,
;; including a nil answer, keeps today's routing.
;;
;; Behavior only; the undo record lives in `fen.extensions.steering.state`.

(local state (require :fen.extensions.steering.state))
(local service (require :fen.extensions.steering.service))
(local events (require :fen.core.extensions.events))
(local text (require :fen.util.text))

(local M {})

(local MIN-CONFIDENCE 0.7)
(local MAX-LINE-BYTES 2000)
(local MAX-CONTEXT-BYTES 2000)

(local QUESTIONS
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

(fn decision-state [line runtime]
  (let [messages (or (?. runtime :agent :messages) [])]
    {:message (text.utf8-prefix line MAX-LINE-BYTES)
     :latest_user_message (latest-user-message messages)
     :activity (activity messages)}))

(fn decide []
  ;; Resolved at call time: decide is an optional extension with its own reload.
  (require :fen.extensions.decide.service))

;; @doc fen.extensions.steering.classify.apply!
;; kind: function
;; signature: (apply! line runtime turn-id answers) -> nil
;; summary: Act on a busy-line classification while the runtime is still busy on the observed turn-id: a confident follow-up still pending in steering moves to follow-up (recorded for /queue undo), a confident cancel emits a ctrl-c suggestion; anything else, or a finished turn, does nothing.
;; tags: steering classify queue
(fn M.apply! [line runtime turn-id answers]
  (let [answer (?. answers :route)
        choice (when (and answer (= (type answer.confidence) :number)
                          (>= answer.confidence MIN-CONFIDENCE))
                 answer.choice)]
    ;; A decision about a finished turn is stale even if a new turn is running.
    (when (and (?. runtime :busy?) (= (?. runtime :turn-id) turn-id))
      (if (= choice :follow-up)
          (when (. (service.requeue! line :steering :follow-up) :ok)
            (set state.reclassified line)
            (events.emit {:type :info
                          :text "reads as a follow-up, so it waits for this turn · /queue undo to steer now"}))
          (= choice :cancel)
          (events.emit {:type :info
                        :text "reads as a cancel request · ctrl-c cancels the turn"})))
    nil))

;; @doc fen.extensions.steering.classify.observe!
;; kind: function
;; signature: (observe! result ctx) -> nil
;; summary: After the steering input handler queued a plain busy line as steering, start an async decide classification when the decide extension is enabled; the line stays queued as steering meanwhile.
;; tags: steering classify input
(fn M.observe! [result ctx]
  (when (and (= (?. result :action) :queued)
             (= result.queue :steering)
             (?. ctx :busy?)
             ;; Never classify slash text, even if a caller routes it here literally.
             (not= (string.sub result.text 1 1) "/")
             ((. (decide) :enabled?)))
    (let [line result.text
          runtime ctx.state
          turn-id (?. runtime :turn-id)]
      ((. (decide) :ask-async!)
       (decision-state line runtime)
       QUESTIONS
       (fn [answers] (M.apply! line runtime turn-id answers)))))
  nil)

;; @doc fen.extensions.steering.classify.undo!
;; kind: function
;; signature: (undo!) -> {:ok true :queued true :queue :steering}|{:ok false :error msg}
;; summary: Move the last line the classifier sent to follow-up back to the steering queue while it is still pending there.
;; tags: steering classify queue
(fn M.undo! []
  (let [line state.reclassified]
    (set state.reclassified nil)
    (if (= line nil)
        {:ok false :error "nothing to undo"}
        (service.requeue! line :follow-up :steering))))

M
