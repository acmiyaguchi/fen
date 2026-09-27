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
(local MAX-REQUEST-BYTES 2000)

(local QUESTIONS
  {:route {:type :choice
           :instructions (.. "The user typed `message` while a coding agent was still "
                             "working on `current_request` (its latest activity is "
                             "`activity`). Decide what the user wants done with the message.")
           :criteria {:correction (.. "It corrects, redirects, or adds a constraint to the "
                                      "work in progress, so the agent should see it now.")
                      :follow-up (.. "It is a separate request or question that should wait "
                                     "until the current work finishes.")
                      :cancel "It asks the agent to stop or abandon the current work."}}})

(fn message-text [m]
  (if (= (type m.content) :string)
      m.content
      (table.concat (icollect [_ b (ipairs (or m.content []))]
                      (when (= b.type :text) b.text))
                    "\n")))

(fn latest-request [messages]
  (var found "")
  (each [_ m (ipairs messages)]
    (when (= m.role :user)
      (set found (message-text m))))
  found)

(fn activity [messages]
  (let [last (. messages (length messages))
        tools (icollect [_ b (ipairs (or (?. last :content) []))]
                (when (= b.type :tool-call) (tostring b.name)))]
    (if (and (= (?. last :role) :assistant) (> (length tools) 0))
        (.. "running tools: " (table.concat tools ", "))
        (= (?. last :role) :tool-result)
        "reading tool results"
        "generating a response")))

(fn decision-state [line runtime]
  (let [messages (or (?. runtime :agent :messages) [])]
    {:message (text.utf8-prefix line MAX-LINE-BYTES)
     :current_request (text.utf8-prefix (latest-request messages) MAX-REQUEST-BYTES)
     :activity (activity messages)}))

(fn decide []
  ;; Resolved at call time: decide is an optional extension with its own reload.
  (require :fen.extensions.decide.service))

;; @doc fen.extensions.steering.classify.apply!
;; kind: function
;; signature: (apply! line runtime answers) -> nil
;; summary: Act on a busy-line classification: a confident follow-up still pending in steering moves to follow-up (recorded for /queue undo), a confident cancel emits a ctrl-c suggestion, and anything else, or an idle runtime, does nothing.
;; tags: steering classify queue
(fn M.apply! [line runtime answers]
  (let [answer (?. answers :route)
        choice (when (and answer (= (type answer.confidence) :number)
                          (>= answer.confidence MIN-CONFIDENCE))
                 answer.choice)]
    (when (?. runtime :busy?)
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
          runtime ctx.state]
      ((. (decide) :ask-async!)
       (decision-state line runtime)
       QUESTIONS
       (fn [answers] (M.apply! line runtime answers)))))
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
