;; Process-level agent turn lifecycle events: the "user turn complete, presenter idle" boundary.

(local events (require :fen.core.extensions.events))
(local first-line (. (require :fen.util.text) :first-line))

(local M {})

;; @doc fen.turn_lifecycle.complete-event
;; kind: function
;; signature: (complete-event state ok? result-or-error) -> table
;; summary: Build an :agent-turn-complete event for a finished agent turn. Status comes from the Outcome agent.step recorded in agent.outcome (:ok, :error, or :cancelled), never from the last message; a raised turn is :error, and a turn that did not run agent.step is :cancelled for "[cancelled]" and :ok otherwise.
;; tags: agent lifecycle events
(fn M.complete-event [state ok? value]
  (let [agent state.agent
        outcome (?. agent :outcome)
        status (if (not ok?) :error
                   outcome outcome.status
                   (= value "[cancelled]") :cancelled
                   :ok)
        ev {:type :agent-turn-complete
            :agent agent
            : state
            :turn-id state.turn-id
            :status status
            :outcome outcome
            :message-count (length (or (?. agent :messages) []))}]
    (if (= status :error)
        (set ev.error
             (first-line (tostring (or (and ok? (?. outcome :error)) value
                                       "turn failed"))))
        (set ev.result value))
    ev))

;; @doc fen.turn_lifecycle.emit-complete!
;; kind: function
;; signature: (emit-complete! state ok? result-or-error) -> table
;; summary: Emit and return the :agent-turn-complete lifecycle event for a finished agent turn, consuming the agent's recorded step Outcome so a later turn that does not run agent.step cannot read it.
;; tags: agent lifecycle events
(fn M.emit-complete! [state ok? value]
  (let [ev (M.complete-event state ok? value)]
    (when (?. state :agent :outcome)
      (set state.agent.outcome nil))
    (events.emit ev)
    ev))

M
