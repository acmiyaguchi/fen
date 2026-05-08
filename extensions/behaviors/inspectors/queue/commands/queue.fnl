;; Queue and cancellation slash commands.
;;
;; Bare /queue toggles a panel showing the steering and follow-up queues.
;; /queue clear and /queue mode keep their existing transcript-emit
;; behavior since they're actions with audit-trail value.

(local util (require :fen.extensions.queue.util))
(local panel-state (require :fen.extensions.queue.state.queue))

(local M {})

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

(fn truncate-line [s n]
  (let [s (or s "")]
    (if (<= (length s) n) s
        (.. (string.sub s 1 (math.max 0 (- n 1))) "…"))))

(fn queue-rows [state]
  (let [steering (or state.steering-queue [])
        follow-up (or state.follow-up-queue [])
        s-mode (tostring (or state.steering-mode "?"))
        f-mode (tostring (or state.follow-up-mode "?"))
        rows [(heading "Queue")
              (dim (.. "  steering ("
                       (tostring (length steering))
                       ", " s-mode ")"))]]
    (if (= (length steering) 0)
        (table.insert rows (dim "    (empty)"))
        (each [i v (ipairs steering)]
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

(fn box-top [w title]
  (let [head (.. "┌─ " title " ")
        head-cols (+ 4 (length title))
        fill-cols (math.max 0 (- w head-cols 1))]
    (.. head (string.rep "─" fill-cols) "┐")))

(fn box-bottom [w]
  (.. "└" (string.rep "─" (math.max 0 (- w 2))) "┘"))

(fn box-side [w text]
  (let [inner-w (math.max 0 (- w 4))
        text (or text "")
        n (length text)
        clipped (if (> n inner-w) (string.sub text 1 inner-w) text)
        pad (math.max 0 (- inner-w (length clipped)))]
    (.. "│ " clipped (string.rep " " pad) " │")))

(fn bordered-rows [w content]
  (let [out [{:text (box-top w "queue") :style :dim}]]
    (each [_ row (ipairs content)]
      (table.insert out {:text (box-side w row.text) :style row.style}))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn panel-rows [w]
  ;; Throttle to 1 Hz; queue mutations land via slash commands and the input
  ;; loop, so the 1-second refresh is plenty for visual freshness.
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w))
      (let [content (if panel-state.run-state
                        (queue-rows panel-state.run-state)
                        [(heading "Queue") (dim "  (no run state)")])]
        (set panel-state.cached-rows (bordered-rows w content)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0))

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
  (if panel-state.visible?
      (do (set panel-state.visible? false)
          (invalidate-cache!)
          (api.emit {:type :info :text "queue panel: off"}))
      (do
        (api.emit {:type :dismiss})
        (set panel-state.visible? true)
        (invalidate-cache!)
        (api.emit {:type :info :text "queue panel: on"}))))

(fn handle-clear [api state arg2]
  (when (or (= arg2 nil) (= arg2 :steering) (= arg2 :all))
    (set state.steering-queue []))
  (when (or (= arg2 nil) (= arg2 :follow-up)
            (= arg2 :followup) (= arg2 :all))
    (set state.follow-up-queue []))
  (when state.update-queue-status (state.update-queue-status))
  (invalidate-cache!)
  (api.emit {:type :info :text "queue cleared"}))

(fn handle-mode [api state which mode]
  (if (and (or (= mode :one-at-a-time) (= mode :all))
           (or (= which :steering) (= which :follow-up)
               (= which :followup)))
      (do
        (if (= which :steering)
            (set state.steering-mode mode)
            (set state.follow-up-mode mode))
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
                (let [arg1 (util.first-arg args)
                      arg2 (util.nth-arg args 2)
                      arg3 (util.nth-arg args 3)]
                  (if (= arg1 :clear)
                      (handle-clear api state arg2)
                      (= arg1 :mode)
                      (handle-mode api state arg2 arg3)
                      (handle-toggle api))))})

  (api.register :command
    {:name :cancel-all
     :order 20
     :description "Cancel current turn and clear queues"
     :handler (fn [_args state]
                (when state.busy? (set state.cancel-requested? true))
                (set state.steering-queue [])
                (set state.follow-up-queue [])
                (when state.update-queue-status (state.update-queue-status))
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
                 (let [rs panel-state.run-state]
                   {:visible? panel-state.visible?
                    :cached-w panel-state.cached-w
                    :cached-at panel-state.cached-at
                    :has-run-state? (not= rs nil)
                    :steering-count (length (or (?. rs :steering-queue) []))
                    :follow-up-count (length (or (?. rs :follow-up-queue) []))
                    :steering-mode (?. rs :steering-mode)
                    :follow-up-mode (?. rs :follow-up-mode)
                    :busy? (or (?. rs :busy?) false)
                    :cancel-requested? (or (?. rs :cancel-requested?) false)}))})

  (api.on :dismiss
    (fn [ev]
      (when panel-state.visible?
        (set panel-state.visible? false)
        (invalidate-cache!)
        (when ev.announce?
          (api.emit {:type :info :text "queue panel: off"}))))))

M
