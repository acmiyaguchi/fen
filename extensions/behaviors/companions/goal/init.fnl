;; Goal companion extension.
;;
;; /goal starts a bounded autonomous objective run by composing existing
;; primitives: normal turns through api.turn.submit!, todo_write, subagents,
;; steering/follow-up semantics, and visible status/panel/introspection state.
;; This MVP deliberately stays model-driven and bounded; it does not add a
;; second agent loop. It uses the agent-callable compact tool as a conservative
;; context-budget guard before high-context follow-up iterations.

(local state (require :fen.extensions.goal.state))
(local text-util (require :fen.util.text))
(local args-util (require :fen.util.args))
(local tokens (require :fen.util.tokens))

(local trim (. text-util :trim))
(local truncate-line (. text-util :truncate-line))
(local first-arg (. args-util :first-arg))
(local rest-args (. args-util :rest-args))

(local M {})

(local DEFAULT_MAX_ITERATIONS 3)
(local MAX_MAX_ITERATIONS 20)
(local HIGH_CONTEXT_TOKENS 80000)
(local STATUS_VALUES {:continue true :done true :blocked true :error true})

(local BASE_GOAL_PROMPT
  (table.concat
    ["You are running a bounded autonomous goal workflow in fen."
     "Work toward the objective below without waiting for the user unless you are blocked, done, or the iteration cap is reached."
     "Start by restating the objective and drafting or reusing a short plan."
     "Maintain the session todo list with todo_write for non-trivial multi-step work."
     "Use subagents for self-contained scouting, planning, review, or other independent work when helpful."
     "Run appropriate checks before declaring completion."
     "Respect normal tool policy, confirmation surfaces, and project constraints; autonomous continuation never grants permission for destructive or external actions."
     "Stop when the goal is complete, blocked, unsafe, or no useful autonomous next step remains."
     "End every response with one final line exactly shaped as one of:"
     "GOAL_STATUS: continue"
     "GOAL_STATUS: done"
     "GOAL_STATUS: blocked"
     "GOAL_STATUS: error"]
    "\n"))

(fn active-running? []
  (= state.status :running))

(fn visible-status? []
  (not= state.status :idle))

(fn touch! []
  (set state.updated-at (os.time))
  (set state.version (+ (or state.version 0) 1))
  (set state.cached-rows nil))

(fn set-status! [status ?reason]
  (set state.status status)
  (when ?reason (set state.last-reason ?reason))
  (touch!))

(fn emit-decision! [api decision status reason text]
  ;; Keep goal-loop decisions visible while attaching stable fields for
  ;; wildcard event subscribers and transcript/event-log adapters.
  (api.emit {:type :info
             :source :goal
             :decision decision
             :status status
             :reason reason
             :iteration (or state.iteration-count 0)
             :max-iterations (or state.max-iterations DEFAULT_MAX_ITERATIONS)
             :text text}))

(fn reset-run! []
  (set state.status :idle)
  (set state.objective nil)
  (set state.iteration-count 0)
  (set state.max-iterations DEFAULT_MAX_ITERATIONS)
  (set state.last-result nil)
  (set state.last-error nil)
  (set state.last-reason nil)
  (set state.last-marker nil)
  (set state.started-at nil)
  (set state.active-turn-id nil)
  (set state.run-state nil)
  (set state.compaction-required? false)
  (set state.last-compaction nil)
  (set state.retry-iteration? false)
  (touch!))

(fn split-words [s]
  (let [out []]
    (each [word (string.gmatch (or s "") "%S+")]
      (table.insert out word))
    out))

(fn parse-positive-int [s]
  (let [n (tonumber s)]
    (when (and n (= n (math.floor n)) (> n 0)) n)))

(fn clamp-cap [n]
  (math.min (or n DEFAULT_MAX_ITERATIONS) MAX_MAX_ITERATIONS))

(fn parse-start-args [args]
  "Parse /goal start options. Returns opts or nil,error."
  (let [words (split-words args)
        objective []]
    (var cap DEFAULT_MAX_ITERATIONS)
    (var err nil)
    (var i 1)
    (while (and (<= i (length words)) (not err))
      (let [word (. words i)
            eq (or (string.match word "^%-%-max%-iterations=(%d+)$")
                   (string.match word "^%-%-iterations=(%d+)$")
                   (string.match word "^%-%-limit=(%d+)$"))]
        (if eq
            (set cap (parse-positive-int eq))
            (or (= word "--max-iterations") (= word "--iterations")
                (= word "--limit") (= word "-n"))
            (do
              (set i (+ i 1))
              (let [n (parse-positive-int (. words i))]
                (if n
                    (set cap n)
                    (set err (.. "invalid iteration cap after " word)))))
            (table.insert objective word)))
      (set i (+ i 1)))
    (if err
        (values nil err)
        (not cap)
        (values nil "iteration cap must be a positive integer")
        (> (or cap 0) MAX_MAX_ITERATIONS)
        (values nil (.. "iteration cap must be <= " MAX_MAX_ITERATIONS))
        (let [objective (trim (table.concat objective " "))]
          (if (= objective "")
              (values nil "missing objective")
              (values {:objective objective :max-iterations (clamp-cap cap)} nil))))))

(fn context-estimate [run-state]
  (let [agent (?. run-state :agent)]
    (when agent
      (tokens.estimated-context-tokens agent))))

(fn compact-tool-available? [api]
  (var found? false)
  (each [_ rec (ipairs (api.list :tools))]
    (when (= (tostring rec.name) "compact")
      (set found? true)))
  found?)

(fn context-limit-error? [message]
  (let [s (string.lower (tostring (or message "")))]
    (or (string.find s "context window" 1 true)
        (string.find s "context length" 1 true)
        (string.find s "context limit" 1 true)
        (string.find s "too many tokens" 1 true)
        (string.find s "maximum context" 1 true))))

(fn maybe-context-warning! [api run-state]
  (let [n (context-estimate run-state)]
    (when (and n (>= n HIGH_CONTEXT_TOKENS))
      (api.emit {:type :info
                 :text (.. "goal: context is high (~" n " tokens); compact manually with /compact if the run blocks")})
      n)))

(fn marker-status [result]
  (let [raw (string.match (or result "") "GOAL_STATUS:%s*([%w_-]+)")
        key (and raw (string.lower raw))]
    (when (and key (. STATUS_VALUES key))
      key)))

(fn prompt [objective iteration max-iterations ?previous ?compact-required]
  (let [lines [BASE_GOAL_PROMPT
               ""
               (.. "Objective: " objective)
               (.. "Iteration: " iteration " of " max-iterations)]]
    (when ?compact-required
      (table.insert lines "")
      (table.insert lines "CONTEXT BUDGET GUARD: Before doing any other work, call the compact tool once.")
      (table.insert lines "Preserve the objective, plan, changed files, validation results, constraints, and next steps in its guidance.")
      (table.insert lines "If compaction fails or is unavailable, report GOAL_STATUS: blocked instead of continuing blindly."))
    (when ?previous
      (table.insert lines "")
      (table.insert lines "Previous iteration result:")
      (table.insert lines ?previous))
    (table.insert lines "")
    (table.insert lines "If you need another iteration and the cap has not been reached, end with `GOAL_STATUS: continue`.")
    (table.insert lines "If the objective is complete, end with `GOAL_STATUS: done`.")
    (table.insert lines "If user input or manual recovery is required, end with `GOAL_STATUS: blocked` and explain why.")
    (table.insert lines "If the run failed unexpectedly, end with `GOAL_STATUS: error` and summarize the failure.")
    (table.concat lines "\n")))

(fn submit-iteration! [api run-state previous]
  (set state.run-state run-state)
  (maybe-context-warning! api run-state)
  (let [text (prompt state.objective state.iteration-count state.max-iterations previous
                     state.compaction-required?)
        result (api.turn.submit! run-state text {:when-busy :reject :emit-user? false})]
    (if result.ok
        (set state.active-turn-id (or result.turn-id run-state.turn-id))
        (do
          (set state.active-turn-id nil)
          (set state.last-error result.error)))
    (when (not result.ok)
      (set state.last-error result.error)
      (set-status! :error result.error)
      (emit-decision! api :stop :error result.error
                      (.. "goal: error — " (tostring result.error)))
      (api.emit {:type :error :error (.. "/goal: " (tostring result.error))}))
    result))

(fn start-goal! [api args run-state]
  (let [(opts err) (parse-start-args args)]
    (if err
        (api.emit {:type :error :error (.. "/goal: " err)})
        (active-running?)
        (api.emit {:type :info :text "goal: already running; use /goal stop first"})
        (do
          (set state.objective opts.objective)
          (set state.max-iterations opts.max-iterations)
          (set state.iteration-count 1)
          (set state.last-result nil)
          (set state.last-error nil)
          (set state.last-reason nil)
          (set state.last-marker nil)
          (set state.compaction-required? false)
          (set state.last-compaction nil)
          (set state.retry-iteration? false)
          (set state.started-at (os.time))
          (set state.active-turn-id nil)
          (set-status! :running)
          (emit-decision! api :start :running "goal submitted"
                          (.. "goal: started 1/" state.max-iterations " — "
                              (truncate-line state.objective 96)))
          (submit-iteration! api run-state nil)))))

(fn resume-goal! [api run-state]
  (if (not state.objective)
      (api.emit {:type :error :error "/goal resume: no goal objective to resume"})
      (active-running?)
      (api.emit {:type :info :text "goal: already running"})
      (and (not state.retry-iteration?)
           (>= (or state.iteration-count 0) (or state.max-iterations DEFAULT_MAX_ITERATIONS)))
      (api.emit {:type :error :error "/goal resume: iteration cap already reached"})
      (do
        (when (not state.retry-iteration?)
          (set state.iteration-count (+ (or state.iteration-count 0) 1)))
        (set state.retry-iteration? false)
        (set state.last-error nil)
        (set-status! :running "resumed")
        (emit-decision! api :resume :running "resumed by user"
                        (.. "goal: resumed " state.iteration-count "/" state.max-iterations))
        (submit-iteration! api run-state state.last-result))))

(fn stop-goal! [api]
  (let [running? (active-running?)
        run-state state.run-state
        cancel-active? (and running? run-state run-state.busy?)]
    ;; Goal continuations are submitted directly rather than put in the shared
    ;; user follow-up queue. Marking the run stopped invalidates completion
    ;; callbacks; requesting cooperative cancellation also stops an in-flight
    ;; goal turn at its next yield without touching user-owned queue entries.
    (when cancel-active?
      (set run-state.cancel-requested? true))
    (set-status! :stopped "stopped by user")
    (emit-decision!
      api :stop :stopped "stopped by user"
      (if cancel-active?
          "goal: stopped; active goal turn cancellation requested and no follow-up will be started"
          (if running?
              "goal: stopped; no further autonomous iterations will be started"
              "goal: stopped")))))

(fn status-text []
  (if (not state.objective)
      "No goal has been started. Use /goal <objective>."
      (table.concat
        [ (.. "Goal status: " (tostring state.status))
          (.. "Objective: " state.objective)
          (.. "Iteration: " (or state.iteration-count 0) "/" (or state.max-iterations DEFAULT_MAX_ITERATIONS))
          (.. "Last marker: " (tostring (or state.last-marker "none")))
          (.. "Reason: " (tostring (or state.last-reason "none"))) ]
        "\n")))

(fn show-status! [api]
  (api.emit {:type :assistant-text :text (status-text)}))

(fn usage! [api]
  (api.emit {:type :assistant-text
             :text (table.concat
                     ["Usage:"
                      (.. "/goal <objective>                    Start a bounded goal run (default " DEFAULT_MAX_ITERATIONS " iterations)")
                      (.. "/goal --max-iterations N <objective> Start with an explicit iteration cap (max " MAX_MAX_ITERATIONS ")")
                      "/goal status                         Show current goal state"
                      "/goal stop                           Stop future autonomous iterations"
                      "/goal resume                         Resume the last non-running goal if under cap"
                      "/goal panel on|off                   Toggle the goal panel"
                      "/goal clear                          Clear goal state"]
                     "\n")}))

(fn set-visible! [api visible? announce?]
  (set state.visible? visible?)
  (touch!)
  (when announce?
    (api.emit {:type :info
               :text (if visible? "goal panel: on" "goal panel: off")})))

(fn handle-command [api args run-state]
  (let [cmd (first-arg args)
        lower (and cmd (string.lower cmd))]
    (if (or (= lower nil) (= lower "") (= lower "help") (= lower "--help") (= lower "-h"))
        (usage! api)
        (= lower "status")
        (show-status! api)
        (= lower "stop")
        (stop-goal! api)
        (= lower "resume")
        (resume-goal! api run-state)
        (= lower "clear")
        (do (reset-run!)
            (api.emit {:type :info :text "goal: cleared"}))
        (= lower "panel")
        (let [arg (string.lower (or (first-arg (rest-args args)) ""))]
          (if (= arg "on")
              (set-visible! api true true)
              (= arg "off")
              (set-visible! api false true)
              (set-visible! api (not state.visible?) true)))
        (start-goal! api args run-state))))

(fn finish-with! [api status reason]
  (set state.last-reason reason)
  (set-status! status reason)
  (emit-decision! api :stop status reason
                  (.. "goal: " (tostring status) " after "
                      (or state.iteration-count 0) "/" (or state.max-iterations DEFAULT_MAX_ITERATIONS)
                      (if reason (.. " — " reason) ""))))

(fn continue-now! [api result ev compact-required?]
  (set state.iteration-count (+ (or state.iteration-count 0) 1))
  (set state.compaction-required? compact-required?)
  (touch!)
  (emit-decision! api :continue :running
                  (if compact-required?
                      "model requested continuation; context compaction required"
                      "model requested continuation")
                  (.. "goal: continuing " state.iteration-count "/" state.max-iterations
                      (if compact-required? " with required context compaction" "")))
  (submit-iteration! api (or state.run-state (?. ev :state)) result))

(fn continue-or-cap! [api result ev]
  (if (>= (or state.iteration-count 0) (or state.max-iterations DEFAULT_MAX_ITERATIONS))
      (finish-with! api :cap-reached "iteration cap reached")
      (let [run-state (or state.run-state (?. ev :state))
            estimate (context-estimate run-state)
            compact? (and estimate (>= estimate HIGH_CONTEXT_TOKENS))]
        (if (and compact? (not (compact-tool-available? api)))
            (finish-with! api :blocked
                          (.. "context budget reached (~" estimate
                              " tokens) and compact is unavailable; run /compact manually"))
            (do
              (when compact?
                (api.emit {:type :info
                           :text (.. "goal: context budget reached (~" estimate
                                     " tokens); requiring compact before more work")}))
              (continue-now! api result ev compact?))))))

(fn handle-success! [api ev]
  (let [result (or ev.result "")
        marker (marker-status result)]
    (set state.last-result result)
    (set state.last-marker marker)
    (if state.compaction-required?
        (do
          (set state.retry-iteration? true)
          (finish-with! api :blocked
                        "required compaction did not complete; run /compact manually, then /goal resume"))
        (not marker)
        (finish-with! api :blocked "missing GOAL_STATUS marker")
        (= marker "done")
        (finish-with! api :done "model reported done")
        (= marker "blocked")
        (finish-with! api :blocked "model reported blocked")
        (= marker "error")
        (finish-with! api :error "model reported error")
        (= marker "continue")
        (continue-or-cap! api result ev))))

(fn matching-agent? [ev]
  (= ev.agent (?. state.run-state :agent)))

(fn matching-turn? [ev]
  (= ev.turn-id state.active-turn-id))

(fn on-turn-complete [api ev]
  (when (and (active-running?) (matching-agent? ev) (matching-turn? ev))
    (if (= ev.status :cancelled)
        (finish-with! api :stopped "turn cancelled")
        (= ev.status :error)
        (do
          (set state.last-error ev.error)
          (if state.compaction-required?
              (do
                (set state.retry-iteration? true)
                (finish-with! api :blocked
                              (.. "automatic compaction failed: " (or ev.error "goal turn failed")
                                  "; run /compact manually, then /goal resume")))
              (context-limit-error? ev.error)
              (do
                (set state.retry-iteration? true)
                (finish-with! api :blocked
                              (.. "provider context limit reached: " (or ev.error "unknown error")
                                  "; run /compact, then /goal resume")))
              (finish-with! api :error (or ev.error "goal turn failed"))))
        (handle-success! api ev))))

(fn on-error [ev]
  ;; :error is a broad surface event and commonly precedes the authoritative
  ;; :agent-turn-complete lifecycle event. Record it for diagnostics without
  ;; ending a goal early; completion classifies provider/context failures.
  (when (active-running?)
    (set state.last-error ev.error)
    (touch!)))

(fn on-compaction-summary [ev]
  (let [agent-success? (and (active-running?)
                            state.compaction-required?
                            (= ev.trigger :agent)
                            (matching-agent? ev))
        manual-recovery? (and (= state.status :blocked)
                              state.compaction-required?
                              state.retry-iteration?
                              (= ev.trigger :manual)
                              (matching-agent? ev))]
    (when (or agent-success? manual-recovery?)
      (set state.compaction-required? false)
      (set state.last-compaction {:tokens-before ev.tokens-before
                                  :tokens-after ev.tokens-after
                                  :trigger ev.trigger})
      (touch!))))

(fn on-reset [_]
  (reset-run!))

(fn status-render [_ctx]
  (when (visible-status?)
    {:text (if (= state.status :running)
               (.. "goal:" (or state.iteration-count 0) "/" (or state.max-iterations DEFAULT_MAX_ITERATIONS))
               (.. "goal:" (tostring state.status)))
     :style :status}))

(fn row [text style]
  {:text text :style (or style :dim)})

(fn panel-lines [w]
  (let [width (math.max 20 (or w 80))
        rows [(row (.. "Goal: " (tostring state.status)) :assistant)]]
    (when state.objective
      (table.insert rows (row (.. "Objective: " (truncate-line state.objective (- width 12))) :dim)))
    (table.insert rows (row (.. "Iteration: " (or state.iteration-count 0) "/" (or state.max-iterations DEFAULT_MAX_ITERATIONS)) :dim))
    (when state.last-reason
      (table.insert rows (row (.. "Reason: " (truncate-line state.last-reason (- width 8))) :dim)))
    (when state.last-result
      (table.insert rows (row "Last result:" :dim))
      (each [line (string.gmatch state.last-result "([^\n]+)")]
        (when (< (length rows) 8)
          (table.insert rows (row (.. "  " (truncate-line line (- width 4))) :dim)))))
    rows))

(fn panel-rows [ctx]
  (let [w (or (?. ctx :w) 80)]
    (when (or (not state.cached-rows)
              (not= state.cached-w w)
              (not= state.cached-version state.version))
      (set state.cached-rows (panel-lines w))
      (set state.cached-w w)
      (set state.cached-version state.version))
    state.cached-rows))

(fn panel-spec []
  {:name :goal
   :placement :above-input
   :order 33
   :height (fn [ctx]
             (if (and state.visible? (visible-status?))
                 (length (panel-rows ctx))
                 0))
   :render (fn [ctx]
             (if (and state.visible? (visible-status?))
                 (panel-rows ctx)
                 []))})

(fn snapshot [_ctx]
  {:status state.status
   :visible? state.visible?
   :objective state.objective
   :iteration-count state.iteration-count
   :max-iterations state.max-iterations
   :last-result state.last-result
   :last-error state.last-error
   :last-reason state.last-reason
   :last-marker state.last-marker
   :compaction-required? state.compaction-required?
   :last-compaction state.last-compaction
   :retry-iteration? state.retry-iteration?
   :started-at state.started-at
   :updated-at state.updated-at})

(fn register! [api]
  (api.register :command
    {:name :goal
     :order 30
     :description "Run a bounded autonomous goal workflow"
     :handler (fn [args run-state]
                (handle-command api args run-state))})
  (api.register :status
    {:name :goal
     :side :left
     :order 33
     :render status-render})
  (api.register :panel (panel-spec))
  (api.register :introspect
    {:name :state
     :description "Current bounded goal workflow state"
     :snapshot snapshot})
  (api.on :agent-turn-complete (fn [ev] (on-turn-complete api ev)))
  (api.on :compaction-summary on-compaction-summary)
  (api.on :error on-error)
  (api.on :reset-conversation on-reset)
  true)

(set M.register register!)
(set M.register! register!)
(set M._state state)
(set M._test {:parse-start-args parse-start-args
              :marker-status marker-status
              :context-limit-error? context-limit-error?
              :prompt prompt})

M
