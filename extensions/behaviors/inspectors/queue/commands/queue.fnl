;; Queue and cancellation slash commands.
;;
;; Bare /queue toggles a panel showing the steering and follow-up queues.
;; /queue clear and /queue mode keep their existing transcript-emit
;; behavior since they're actions with audit-trail value.

(local args-util (require :fen.util.args))
(local truncate-line (. (require :fen.util.text) :truncate-line))
(local panel (require :fen.util.panel))
(local panel-state (require :fen.extensions.queue.state.queue))
(local steering (require :fen.extensions.steering.service))
(local types (require :fen.core.types))

(local M {})

(local dim panel.dim)
(local heading panel.heading)

(fn queue-rows []
  (let [snap (steering.queue-snapshot)
        steering-lines snap.steering
        follow-up snap.follow-up
        s-mode (tostring (or snap.steering-mode "?"))
        f-mode (tostring (or snap.follow-up-mode "?"))
        rows [(heading "Queue")
              (dim (.. "  steering ("
                       (tostring (length steering-lines))
                       ", " s-mode ")"))]]
    (if (= (length steering-lines) 0)
        (table.insert rows (dim "    (empty)"))
        (each [i v (ipairs steering-lines)]
          (table.insert rows
                        (dim (.. "    " (tostring i) ". "
                                 (truncate-line (tostring v) 96))))))
    (table.insert rows
                  (dim (.. "  follow-up ("
                           (tostring (length follow-up))
                           ", " f-mode ")")))
    (if (= (length follow-up) 0)
        (table.insert rows (dim "    (empty)"))
        (each [i v (ipairs follow-up)]
          (table.insert rows
                        (dim (.. "    " (tostring i) ". "
                                 (truncate-line (tostring v) 96))))))
    rows))

(fn panel-rows [w]
  ;; Throttle to 1 Hz; queue mutations land via slash commands and the input
  ;; loop, so the 1-second refresh is plenty for visual freshness.
  (panel.throttled-rows panel-state w "queue" queue-rows))

(fn invalidate-cache! []
  (panel.invalidate-cache! panel-state))

(fn panel-spec []
  {:name :queue
   :placement :above-input
   :order 30
   :height (fn [ctx]
             (if panel-state.visible?
                 (length (panel-rows (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if panel-state.visible?
                 (panel-rows (or (?. ctx :w) 80))
                 []))})

(fn handle-toggle [api]
  (panel.toggle! panel-state api.emit "queue"))

(fn canonical [value]
  (let [s (tostring (or value ""))
        s (if (= (string.sub s 1 1) ":") (string.sub s 2) s)]
    (if (= s "followup") "follow-up" s)))

(fn snapshot-details [action]
  (let [snap (steering.queue-snapshot)]
    {:action action
     :steering snap.steering
     :follow-up snap.follow-up
     :steering-mode snap.steering-mode
     :follow-up-mode snap.follow-up-mode}))

(fn perform-clear [target]
  (let [target (canonical target)]
    (if (not (or (= target "steering") (= target "follow-up") (= target "all")))
        (values nil "clear target must be steering, follow-up, or all")
        (let [before (steering.queue-snapshot)
              kind (if (= target "steering") :steering
                       (= target "follow-up") :follow-up
                       :all)]
          (steering.clear-queues! kind)
          (invalidate-cache!)
          (let [details (snapshot-details :clear)]
            (set details.target kind)
            (set details.cleared
                 {:steering (if (or (= kind :steering) (= kind :all))
                                (length before.steering) 0)
                  :follow-up (if (or (= kind :follow-up) (= kind :all))
                                 (length before.follow-up) 0)})
            (values details nil))))))

(fn perform-set-mode [which mode]
  (let [which (canonical which)
        mode (canonical mode)
        kind (if (= which "steering") :steering
                 (= which "follow-up") :follow-up
                 nil)
        mode-key (if (= mode "one-at-a-time") :one-at-a-time
                     (= mode "all") :all
                     nil)]
    (if (not kind)
        (values nil "queue must be steering or follow-up")
        (not mode-key)
        (values nil "mode must be one-at-a-time or all")
        (do
          (steering.set-queue-mode! kind mode-key)
          (invalidate-cache!)
          (let [details (snapshot-details :set_mode)]
            (set details.queue kind)
            (set details.mode mode-key)
            (values details nil))))))

(fn tool-result [text is-error? ?details]
  (let [result {:content [(types.text-block text)]
                :is-error? (or is-error? false)}]
    (when ?details (set result.details ?details))
    result))

(fn handle-clear [api arg2]
  (let [(details err) (perform-clear (or arg2 :all))]
    (if err
        (api.emit {:type :error :error err})
        (api.emit {:type :info
                   :text (.. "queue cleared: " (tostring details.target))}))))

(fn handle-mode [api which mode]
  (let [(details err) (perform-set-mode which mode)]
    (if err
        (api.emit
          {:type :error
           :error "usage: /queue mode steering|follow-up one-at-a-time|all"})
        (api.emit
          {:type :info
           :text (.. "queue mode " (tostring details.queue)
                     " = " (tostring details.mode))}))))

(fn execute-tool [_args]
  ;; Agent access is deliberately read-only: queued lines may be user-authored
  ;; steering, so clearing or changing drain policy remains an explicit command.
  (tool-result "Queue snapshot." false (snapshot-details :list)))

;; @doc fen.extensions.queue.commands.queue.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register queue management commands and the queue panel for pending steering/follow-up lines.
;; tags: commands queue register
(fn M.register [api]
  (api.register :command
    {:name :queue
     :order 10
     :description "Toggle the queue panel; /queue clear|mode preserve their actions"
     :handler (fn [args state]
                (when state (set panel-state.run-state state))
                (let [arg1 (args-util.first-arg args)
                      arg2 (args-util.nth-arg args 2)
                      arg3 (args-util.nth-arg args 3)]
                  (if (= arg1 :clear)
                      (handle-clear api arg2)
                      (= arg1 :mode)
                      (handle-mode api arg2 arg3)
                      (handle-toggle api))))})

  (api.register :tool
    {:name :queue
     :label "Queue"
     :exposure :search
     :snippet "Inspect steering and follow-up queues"
     :description "Inspect pending steering and follow-up input. This agent-facing tool is read-only; use /queue for explicit user-owned clear and mode changes."
     :parameters {:type :object :properties {}}
     :execute (fn [args _ctx] (execute-tool args))})

  (api.register :command
    {:name :cancel-all
     :order 20
     :description "Cancel current turn and clear queues"
     :handler (fn [_args state]
                (when state.busy? (set state.cancel-requested? true))
                (steering.clear-queues!)
                (invalidate-cache!)
                (api.emit
                  {:type :info
                   :text "cancel requested; queues cleared"}))})

  ;; @doc register-site:panel:queue
  ;; summary: Queued follow-up/cancel-all panel backing queue-management commands.
  ;; tags: panel queue commands
  (api.register :panel (panel-spec))

  (api.register :introspect
    {:name :panel
     :description "Current queue panel and pending steering/follow-up counts"
     :snapshot (fn [_]
                 (let [rs panel-state.run-state
                       info (steering.queue-info)]
                   {:visible? panel-state.visible?
                    :cached-w panel-state.cached-w
                    :cached-at panel-state.cached-at
                    :has-run-state? (not= rs nil)
                    :steering-count info.steering-queued
                    :follow-up-count info.follow-up-queued
                    :steering-mode info.steering-mode
                    :follow-up-mode info.follow-up-mode
                    :busy? (or (?. rs :busy?) false)
                    :cancel-requested? (or (?. rs :cancel-requested?) false)}))})

  (api.on :dismiss
    (fn [ev] (panel.dismissed! panel-state api.emit "queue" ev))))

M
