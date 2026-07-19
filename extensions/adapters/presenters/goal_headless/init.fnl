;; Headless presenter for `fen goal`.
;;
;; The presenter starts the existing /goal command and drives the ordinary
;; cooperative turn loop. Goal policy, prompts, continuation, persistence, and
;; bounds remain owned by the goal companion rather than being reimplemented
;; here.

(local goal-state (require :fen.extensions.goal.state))
(local headless-progress (require :fen.util.headless_progress))
(local M {})

(local EXIT-CODES
  {:done 0
   :blocked 2
   :cap-reached 2
   :stopped 2
   :error 1})

(fn command-for [opts]
  (.. "/goal start --max-iterations " (tostring opts.max-iterations)
      " -- " opts.objective))

(fn M.run [ctx]
  (let [state ctx.state
        opts state.opts]
    (ctx.on-submit (command-for opts))
    (while (= goal-state.status :running)
      (if (and ctx.is-busy? (ctx.is-busy?))
          (ctx.on-tick)
          (error "goal stopped making progress without a terminal status")))
    (when goal-state.last-result
      (io.write goal-state.last-result)
      (when (not= (string.sub goal-state.last-result -1) "\n")
        (io.write "\n")))
    (or (. EXIT-CODES goal-state.status)
        (error (.. "goal ended with unexpected status: "
                   (tostring goal-state.status))))))

(fn M.register [api]
  (headless-progress.register api)
  (api.on :error
          (fn [ev]
            (io.stderr:write (.. "error: " (tostring ev.error) "\n"))))
  (api.register :presenter
                {:name :goal-headless
                 :active? true
                 :init (fn [_ctx] nil)
                 :run M.run
                 :shutdown (fn [_ctx] nil)})
  true)

(set M._test {:command-for command-for :exit-codes EXIT-CODES})

M
