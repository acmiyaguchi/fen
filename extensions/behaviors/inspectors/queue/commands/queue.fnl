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

(fn handle-clear [api arg2]
  (when (or (= arg2 nil) (= arg2 :steering) (= arg2 :all))
    (steering.clear-queues! :steering))
  (when (or (= arg2 nil) (= arg2 :follow-up)
            (= arg2 :followup) (= arg2 :all))
    (steering.clear-queues! :follow-up))
  (invalidate-cache!)
  (api.emit {:type :info :text "queue cleared"}))

(fn handle-mode [api which mode]
  (if (steering.set-queue-mode! which mode)
      (do
        (invalidate-cache!)
        (api.emit
          {:type :info
           :text (.. "queue mode " (tostring which)
                     " = " (tostring mode))}))
      (api.emit
        {:type :error
         :error "usage: /queue mode steering|follow-up one-at-a-time|all"})))

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
