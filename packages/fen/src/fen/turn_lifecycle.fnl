;; Helpers for process-level agent turn lifecycle events.
;;
;; Core agent/provider events describe provider calls, streaming blocks, tool
;; calls, and message appends. This module owns the higher-level "the submitted
;; user turn is complete and the presenter is idle again" boundary that lives in
;; fen/main.fnl around the cooperative turn coroutine.

(local events (require :fen.core.extensions.events))
(local first-line (. (require :fen.util.text) :first-line))

(local M {})

(fn last-message [agent]
  (let [messages (or (?. agent :messages) [])]
    (. messages (length messages))))

(fn cancelled-turn? [agent result]
  (or (= result "[cancelled]")
      (= (?. (last-message agent) :stop-reason) :aborted)))

(fn error-turn? [agent]
  (= (?. (last-message agent) :stop-reason) :error))

(fn turn-error-message [agent fallback]
  (first-line (or (?. (last-message agent) :error-message) fallback)))

;; @doc fen.turn_lifecycle.complete-event
;; kind: function
;; signature: (complete-event state ok? result-or-error) -> table
;; summary: Build an :agent-turn-complete event for a finished agent turn.
;; tags: agent lifecycle events
(fn M.complete-event [state ok? value]
  (let [agent state.agent
        status (if (not ok?)
                   :error
                   (if (cancelled-turn? agent value)
                       :cancelled
                       (if (error-turn? agent) :error :ok)))
        ev {:type :agent-turn-complete
            :agent agent
            :status status
            :message-count (length (or (?. agent :messages) []))}]
    (if (= status :error)
        (set ev.error (turn-error-message agent value))
        (set ev.result value))
    ev))

;; @doc fen.turn_lifecycle.emit-complete!
;; kind: function
;; signature: (emit-complete! state ok? result-or-error) -> table
;; summary: Emit and return the :agent-turn-complete lifecycle event for a finished agent turn.
;; tags: agent lifecycle events
(fn M.emit-complete! [state ok? value]
  (let [ev (M.complete-event state ok? value)]
    (events.emit ev)
    ev))

M
