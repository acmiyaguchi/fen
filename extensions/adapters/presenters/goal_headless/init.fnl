;; Headless presenter for `fen goal`.
;;
;; The presenter starts the existing /goal command and drives the ordinary
;; cooperative turn loop. Goal policy, prompts, continuation, persistence, and
;; bounds remain owned by the goal companion rather than being reimplemented
;; here.

(local goal-state (require :fen.extensions.goal.state))
(local headless-progress (require :fen.util.headless_progress))
(local json (require :fen.util.json))
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

(fn outcome-status [status]
  (if (= status :done) "done"
      (= status :cap-reached) "iteration-cap"
      (or (= status :blocked) (= status :stopped)) "blocked"
      "failure"))

(fn outcome [started-at-ms ?failure]
  (let [status (if ?failure :error goal-state.status)
        result-status (outcome-status status)
        now-ms (* (os.time) 1000)
        reason (or ?failure goal-state.last-reason
                   (if (= result-status "failure") "goal runtime failure" "goal finished"))]
    {:status result-status
     :reason (tostring reason)
     :iterations-used (or goal-state.iteration-count 0)
     ;; os.time is wall-clock seconds on the supported Lua runtime; retain the
     ;; documented millisecond unit even though its resolution is one second.
     :wall-clock-ms (math.max 0 (- now-ms started-at-ms))}))

(fn final-marker [status]
  ;; The plain-text companion contract has no iteration-cap marker; the cap is
  ;; an incomplete/blocked outcome while JSON preserves the finer distinction.
  (if (= status "done") "done"
      (or (= status "blocked") (= status "iteration-cap")) "blocked"
      "error"))

(fn write-json-outcome! [path result value]
  (let [(ok? encoded) (pcall json.encode {:final-text result
                                           :goal value})]
    (if (not ok?)
        false
        (let [(f err) (io.open path :w)]
          (if f
              ;; Lua 5.4 file:write and file:close return nil,err on failure
              ;; (e.g. a full disk or a truncated flush). Check both so a short
              ;; write is never reported as success.
              (let [(wrote? write-err) (f:write encoded "\n")
                    (closed? close-err) (f:close)]
                (if (and wrote? closed?)
                    true
                    (do (io.stderr:write
                          (.. "goal presenter: cannot write " path ": "
                              (tostring (or write-err close-err)) "\n"))
                        false)))
              (do (io.stderr:write (.. "goal presenter: cannot write " path ": "
                                       (tostring err) "\n"))
                  false))))))

(fn write-plain-outcome! [result value]
  (let [marker (.. "GOAL_STATUS: " (final-marker value.status))]
    (when result
      (io.write result)
      (when (not= (string.sub result -1) "\n")
        (io.write "\n")))
    ;; The model may have produced an earlier continuation marker before a cap
    ;; or runtime failure. Emit the authoritative terminal marker last, unless
    ;; the result already ends in that exact marker.
    (when (not (and result (string.match result (.. marker "%s*$"))))
      (io.write (.. marker "\n")))))

(fn run-goal! [ctx]
  (let [state ctx.state
        opts state.opts]
    (ctx.on-submit (command-for opts))
    (while (= goal-state.status :running)
      (if (and ctx.is-busy? (ctx.is-busy?))
          (ctx.on-tick)
          (error "goal stopped making progress without a terminal status")))
    (or (. EXIT-CODES goal-state.status)
        (error (.. "goal ended with unexpected status: "
                   (tostring goal-state.status))))))

(fn M.run [ctx]
  (let [started-at-ms (* (os.time) 1000)
        (ok? code-or-error) (xpcall #(run-goal! ctx) debug.traceback)
        value (outcome started-at-ms (when (not ok?) code-or-error))
        json-path (or (?. ctx :state :opts :json-output-file)
                      (os.getenv :FEN_JSON_OUTPUT_PATH))
        wrote? (if (and json-path (not= json-path ""))
                   (write-json-outcome! json-path goal-state.last-result value)
                   (do (write-plain-outcome! goal-state.last-result value) true))]
    (if (and ok? wrote?)
        (or code-or-error 1)
        1)))

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

(set M._test {:command-for command-for
              :exit-codes EXIT-CODES
              :outcome-status outcome-status
              :outcome outcome})

M
