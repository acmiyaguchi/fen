;; One-shot stdout presenter used by `fen --print TEXT`.
;;
;; This intentionally has no UI slot and no interactive lifecycle. Main owns
;; agent/session setup; this presenter performs exactly one agent step, prints
;; the final assistant text, and returns so the shared presenter runner can
;; flush/close/shutdown like every other presenter.

(local agent-mod (require :fen.core.agent))
(local turn-lifecycle (require :fen.turn_lifecycle))

(local M {})

;; @doc fen.extensions.print.run
;; kind: function
;; signature: (run ctx) -> nil
;; summary: Execute the one-shot print presenter by stepping the agent with the supplied prompt and printing the final text.
;; tags: print presenter run
(fn M.run [ctx]
  (let [state ctx.state
        prompt (or (?. state :opts :print) ctx.prompt)]
    (when (not prompt)
      (error "print presenter requires a prompt"))
    (let [(ok? result) (xpcall #(agent-mod.step state.agent prompt) debug.traceback)]
      (turn-lifecycle.emit-complete! state ok? result)
      (if ok?
          (print result)
          (error result)))))

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
