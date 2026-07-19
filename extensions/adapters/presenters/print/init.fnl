;; One-shot stdout presenter used by `fen --print TEXT`.
;;
;; This intentionally has no UI slot and no interactive lifecycle. Main owns
;; agent/session setup; this presenter performs exactly one agent step, prints
;; the final assistant text, and returns so the shared presenter runner can
;; flush/close/shutdown like every other presenter.

(local agent-mod (require :fen.core.agent))
(local turn-lifecycle (require :fen.turn_lifecycle))

(local M {})

(fn last-assistant [messages]
  "Return the most recent assistant message, or nil. agent.step records a turn's
   stop-reason on this message (agent.fnl appends one assistant message per
   provider call)."
  (let [msgs (or messages [])]
    (var found nil)
    (for [i (length msgs) 1 -1 &until found]
      (let [m (. msgs i)]
        (when (= m.role :assistant)
          (set found m))))
    found))

(fn failed-turn? [ok? asst]
  "A one-shot turn failed when the step raised, when no assistant message was
   produced, or when the last assistant message records a non-final turn state.
   A provider/HTTP failure does not raise: agent.step records stop-reason :error,
   emits an :error event, and returns an \"[error] ...\" string, so `ok?` alone
   would report a failed turn as success. A final :tool-use means the agent hit
   its safety cap before a natural stop."
  (or (not ok?)
      (not asst)
      (= (?. asst :stop-reason) :error)
      (= (?. asst :stop-reason) :tool-use)
      (= (?. asst :stop-reason) :aborted)))

;; @doc fen.extensions.print.run
;; kind: function
;; signature: (run ctx) -> nil
;; summary: Execute the one-shot print presenter by stepping the agent with the supplied prompt, printing final text, and exiting 1 when the turn fails.
;; tags: print presenter run
(fn M.run [ctx]
  (let [state ctx.state
        prompt (or (?. state :opts :print) ctx.prompt)]
    (when (not prompt)
      (error "print presenter requires a prompt"))
    (let [(ok? result) (xpcall #(agent-mod.step state.agent prompt) debug.traceback)]
      (turn-lifecycle.emit-complete! state ok? result)
      (if (not ok?)
          ;; The step raised unexpectedly. Propagate so the shared presenter
          ;; runner reports the crash and exits non-zero.
          (error result)
          (let [asst (last-assistant (?. state :agent :messages))]
            (if (failed-turn? ok? asst)
                ;; No assistant reply was produced (e.g. a provider/HTTP error,
                ;; cancellation, or safety-cap exhaustion). Do not print the
                ;; "[error] ..."/"[cancelled]" blob to stdout as if it were the
                ;; reply, and exit non-zero so scripts/harnesses can detect the
                ;; failure.
                (os.exit 1)
                (print result)))))))

(fn M.register [api]
  (api.on :error
          (fn [ev]
            (io.stderr:write (.. "error: " (tostring ev.error) "\n"))))

  (api.register :presenter
                {:name :print
                 :active? true
                 :init (fn [_ctx] nil)
                 :run (fn [ctx] (M.run ctx))
                 :shutdown (fn [_ctx] nil)})
  true)

M
