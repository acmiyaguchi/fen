;; Plan companion extension.
;;
;; /plan asks the model to draft or revise a read-only implementation plan.
;; While a plan turn is running, a before-tool hook allows only inspection tools.
;; /plan approve submits the captured plan as a normal user turn for execution.

(local state (require :fen.extensions.plan.state))
(local trim (. (require :fen.util.text) :trim))

(local M {})

(local READ_ONLY_TOOLS
  {:read true
   :grep true
   :find true
   :ls true
   :agent_state true
   :fen_docs true})

(local PLAN_PROMPT
  (table.concat
    ["Enter plan mode for this request."
     "Investigate only with read-only tools."
     "Allowed tools while planning: read, grep, find, ls, agent_state, fen_docs."
     "Do not use bash, edit, write, or any tool that mutates files, state, sessions, or external systems."
     "Produce a concise execution plan only; do not make changes yet."
     "Include risks, files likely to change, and tests/checks to run."
     "End with a short note that the user can run /plan approve to execute or /plan revise <guidance> to revise."]
    "\n"))

(local REVISE_PROMPT
  (table.concat
    ["Revise the current plan using the user's guidance."
     "Continue plan mode and continue using only read-only tools if more inspection is needed."
     "Produce the revised execution plan only; do not make changes yet."]
    "\n"))

(fn first-arg [args]
  (string.match (or args "") "^%s*(%S+)"))

(fn rest-args [args]
  (or (string.match (or args "") "^%s*%S+%s*(.-)%s*$") ""))

(fn tool-key [name]
  (let [s (tostring (or name ""))]
    (if (= (string.sub s 1 1) ":")
        (string.sub s 2)
        s)))

(fn planning? []
  (or (= state.mode :planning)
      (= state.mode :revising)))

(fn active? []
  (not= state.mode :idle))

(fn touch! []
  (set state.updated-at (os.time))
  ;; Monotonic key the panel cache invalidates on; see panel-rows.
  (set state.version (+ (or state.version 0) 1)))

(fn clear-blocked! []
  (set state.last-blocked nil))

(fn remember-blocked! [name]
  ;; `name` is already normalized by the before-tool caller.
  (when (and name (not= name ""))
    (set state.last-blocked name)
    (touch!)))

(fn set-mode! [mode]
  (set state.mode mode)
  (touch!))

(fn clear-plan! []
  (set state.mode :idle)
  (set state.last-plan nil)
  (set state.last-goal nil)
  (set state.last-error nil)
  (set state.revision-count 0)
  (clear-blocked!)
  (touch!))

(fn planning-prompt [goal]
  (let [goal (trim goal)]
    (table.concat
      [PLAN_PROMPT
       ""
       "User request to plan:"
       (if (= goal "") "Plan the next requested work from the conversation context." goal)]
      "\n")))

(fn revision-prompt [guidance]
  (table.concat
    [REVISE_PROMPT
     ""
     "Current plan:"
     (or state.last-plan "")
     ""
     "Revision guidance:"
     (trim guidance)]
    "\n"))

(fn approved-text []
  (table.concat
    ["Approved plan:"
     ""
     (or state.last-plan "")
     ""
     "Execute this plan now."]
    "\n"))

(fn submit-plan-turn! [api run-state prompt mode goal]
  (clear-blocked!)
  (set state.last-error nil)
  (set-mode! mode)
  (when goal (set state.last-goal goal))
  (let [result (api.turn.submit! run-state prompt {:when-busy :reject
                                                  :emit-user? false})]
    (when (not result.ok)
      (set state.last-error result.error)
      (set-mode! :idle)
      (api.emit {:type :error :error (.. "/plan: " (tostring result.error))}))
    result))

(fn start-plan! [api args run-state]
  (submit-plan-turn! api run-state (planning-prompt args) :planning (trim args)))

(fn revise-plan! [api args run-state]
  (if (not state.last-plan)
      (api.emit {:type :error :error "/plan revise: no captured plan to revise"})
      (do
        (set state.revision-count (+ (or state.revision-count 0) 1))
        (submit-plan-turn! api run-state (revision-prompt args) :revising state.last-goal))))

(fn approve-plan! [api _args run-state]
  (if (not state.last-plan)
      (api.emit {:type :error :error "/plan approve: no captured plan to approve"})
      (let [text (approved-text)]
        ;; Execution is no longer plan mode; normal tools are available.
        (set-mode! :idle)
        (let [result (api.turn.submit! run-state text {:when-busy :reject})]
          (when (not result.ok)
            (set state.last-error result.error)
            (api.emit {:type :error :error (.. "/plan approve: " (tostring result.error))}))
          result))))

(fn show-plan! [api]
  (if state.last-plan
      (api.emit {:type :assistant-text
                 :text (.. "Current plan:\n\n" state.last-plan)})
      (api.emit {:type :assistant-text
                 :text "No plan captured yet. Use /plan <request> to draft one."})))

(fn usage! [api]
  (api.emit {:type :assistant-text
             :text (table.concat
                     ["Usage:"
                      "/plan <request>      Draft a read-only plan"
                      "/plan revise <notes> Revise the captured plan"
                      "/plan approve        Execute the captured plan"
                      "/plan show           Show the captured plan"
                      "/plan cancel         Leave plan mode and clear the plan"
                      "/plan panel on|off   Toggle the plan panel"]
                     "\n")}))

(fn set-visible! [api visible? announce?]
  (set state.visible? visible?)
  (touch!)
  (when announce?
    (api.emit {:type :info
               :text (if visible? "plan panel: on" "plan panel: off")})))

(fn handle-command [api args run-state]
  (let [cmd (first-arg args)
        lower (and cmd (string.lower cmd))]
    (if (or (= lower nil) (= lower ""))
        (usage! api)
        (= lower "approve")
        (approve-plan! api (rest-args args) run-state)
        (= lower "revise")
        (revise-plan! api (rest-args args) run-state)
        (= lower "show")
        (show-plan! api)
        (= lower "cancel")
        (do (clear-plan!)
            (api.emit {:type :info :text "plan cleared"}))
        (= lower "panel")
        (let [arg (string.lower (first-arg (rest-args args)))]
          (if (= arg "on")
              (set-visible! api true true)
              (= arg "off")
              (set-visible! api false true)
              (set-visible! api (not state.visible?) true)))
        ;; Treat any other /plan args as a new planning request.
        (start-plan! api args run-state))))

(fn before-tool [tool-name _args _ctx]
  (when (planning?)
    (let [name (tool-key tool-name)]
      (when (not (. READ_ONLY_TOOLS name))
        (remember-blocked! name)
        {:block true
         :reason (.. "plan mode is read-only; tool " name " is not allowed")}))))

(fn on-assistant-text [ev]
  (when (and (planning?) ev.text)
    (set state.last-plan ev.text)
    (set-mode! :ready)))

(fn on-error [ev]
  (when (planning?)
    (set state.last-error ev.error)
    (set-mode! :idle)))

(fn on-reset [_]
  (clear-plan!))

(fn status-render [_ctx]
  (when (active?)
    {:text (.. "plan:" state.mode)
     :style :status}))

(fn truncate-line [s n]
  (let [s (or s "")]
    (if (<= (length s) n) s
        (.. (string.sub s 1 (math.max 0 (- n 1))) "…"))))

(fn plan-summary-lines [w]
  (let [width (math.max 20 (or w 80))
        out [{:text (.. "Plan mode: " state.mode) :style :assistant}]]
    (when state.last-goal
      (table.insert out {:text (.. "Goal: " (truncate-line state.last-goal (- width 8))) :style :dim}))
    (if state.last-plan
        (do
          (table.insert out {:text "Captured plan:" :style :dim})
          (each [line (string.gmatch state.last-plan "([^\n]+)")]
            (when (< (length out) 8)
              (table.insert out {:text (.. "  " (truncate-line line (- width 4))) :style :dim}))))
        (table.insert out {:text "No plan captured yet." :style :dim}))
    (when state.last-blocked
      (table.insert out {:text (.. "Blocked tool: " state.last-blocked)
                         :style :error}))
    out))

(fn panel-rows [ctx]
  ;; :height and :render both call this each frame; cache on (width, version)
  ;; so the row list is built at most once per change, like todo/mem.
  (let [w (or (?. ctx :w) 80)]
    (when (or (not state.cached-rows)
              (not= state.cached-w w)
              (not= state.cached-version state.version))
      (set state.cached-rows (plan-summary-lines w))
      (set state.cached-w w)
      (set state.cached-version state.version))
    state.cached-rows))

(fn panel-spec []
  {:name :plan
   :placement :above-input
   :order 34
   :height (fn [ctx]
             (if (and state.visible? (active?))
                 (length (panel-rows ctx))
                 0))
   :render (fn [ctx]
             (if (and state.visible? (active?))
                 (panel-rows ctx)
                 []))})

(fn snapshot [_ctx]
  {:mode state.mode
   :visible? state.visible?
   :has-plan? (not= state.last-plan nil)
   :last-plan state.last-plan
   :last-goal state.last-goal
   :last-error state.last-error
   :last-blocked state.last-blocked
   :revision-count state.revision-count
   :updated-at state.updated-at})

(fn register! [api]
  (api.register :command
    {:name :plan
     :order 28
     :description "Draft, revise, show, and approve a read-only execution plan"
     :handler (fn [args run-state]
                (handle-command api args run-state))})
  (api.register :hook {:before-tool before-tool})
  (api.register :status
    {:name :plan
     :side :left
     :order 34
     :render status-render})
  (api.register :panel (panel-spec))
  (api.register :introspect
    {:name :state
     :description "Current plan companion mode and captured plan"
     :snapshot snapshot})
  (api.on :assistant-text on-assistant-text)
  (api.on :error on-error)
  (api.on :reset-conversation on-reset)
  true)

(set M.register register!)
(set M.register! register!)
(set M._state state)

M
