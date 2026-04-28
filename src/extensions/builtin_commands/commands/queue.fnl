;; Queue and cancellation slash commands.

(local extensions (require :core.extensions))
(local util (require :extensions.builtin_commands.util))

(local M {})

(fn M.register [api]
  (api.register :command
    {:name :queue
     :order 10
     :description "Show or clear queued steering/follow-up messages"
     :handler (fn [args state]
                (let [arg1 (util.first-arg args)
                      arg2 (util.nth-arg args 2)
                      arg3 (util.nth-arg args 3)]
                  (if (= arg1 :clear)
                      (do
                        (when (or (= arg2 nil) (= arg2 :steering) (= arg2 :all))
                          (set state.steering-queue []))
                        (when (or (= arg2 nil) (= arg2 :follow-up)
                                  (= arg2 :followup) (= arg2 :all))
                          (set state.follow-up-queue []))
                        (when state.update-queue-status (state.update-queue-status))
                        (extensions.emit {:type :info :text "queue cleared"}))
                      (= arg1 :mode)
                      (let [which arg2
                            mode arg3]
                        (if (and (or (= mode :one-at-a-time) (= mode :all))
                                 (or (= which :steering) (= which :follow-up)
                                     (= which :followup)))
                            (do
                              (if (= which :steering)
                                  (set state.steering-mode mode)
                                  (set state.follow-up-mode mode))
                              (extensions.emit
                                {:type :info
                                 :text (.. "queue mode " (tostring which)
                                           " = " (tostring mode))}))
                            (extensions.emit
                              {:type :error
                               :error "usage: /queue mode steering|follow-up one-at-a-time|all"})))
                      (let [lines ["Queue"
                                   (.. "steering ("
                                       (tostring (length (or state.steering-queue [])))
                                       ", " (tostring state.steering-mode) ")")]]
                        (var n 0)
                        (each [_ v (ipairs (or state.steering-queue []))]
                          (set n (+ n 1))
                          (table.insert lines (.. "  " (tostring n) ". " v)))
                        (table.insert lines
                                      (.. "follow-up ("
                                          (tostring (length (or state.follow-up-queue [])))
                                          ", " (tostring state.follow-up-mode) ")"))
                        (set n 0)
                        (each [_ v (ipairs (or state.follow-up-queue []))]
                          (set n (+ n 1))
                          (table.insert lines (.. "  " (tostring n) ". " v)))
                        (table.insert lines "commands: /queue clear [steering|follow-up|all], /queue mode steering|follow-up one-at-a-time|all")
                        (extensions.emit {:type :assistant-text
                                          :text (table.concat lines "\n")})))))})

  (api.register :command
    {:name :cancel-all
     :order 20
     :description "Cancel current turn and clear queues"
     :handler (fn [_args state]
                (when state.busy? (set state.cancel-requested? true))
                (set state.steering-queue [])
                (set state.follow-up-queue [])
                (when state.update-queue-status (state.update-queue-status))
                (extensions.emit
                  {:type :info
                   :text "cancel requested; queues cleared"}))}))

M
