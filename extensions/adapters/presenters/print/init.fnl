;; One-shot stdout presenter for `fen --print`: one agent step, no UI slot; the shared runner owns shutdown.

(local agent-mod (require :fen.core.agent))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local turn-result (require :fen.util.turn_result))
(local headless-progress (require :fen.util.headless_progress))

(local M {})

;; @doc fen.extensions.print.run
;; kind: function
;; signature: (run ctx) -> exit-code
;; summary: Execute the one-shot print presenter by stepping the agent with the supplied prompt, printing final text, and returning a non-zero CLI exit code (1) when the turn fails so the CLI layer owns the process exit.
;; tags: print presenter run
(fn M.run [ctx]
  (let [state ctx.state
        prompt (or (?. state :opts :print) ctx.prompt)]
    (when (not prompt)
      (error "print presenter requires a prompt"))
    (let [(ok? result outcome) (xpcall #(agent-mod.step state.agent prompt)
                                       debug.traceback)
          outcome (or outcome (?. state :agent :outcome))]
      (turn-lifecycle.emit-complete! state ok? result)
      (if (not ok?)
          (error result)
          (let [messages (?. state :agent :messages)]
            (if (turn-result.failed? ok? messages outcome)
                ;; No assistant reply (provider error/cancel/cap): return exit 1 instead of printing the error blob; main owns process exit.
                1
                (do
                  (print result)
                  0)))))))

(fn M.register [api]
  (headless-progress.register api)
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
