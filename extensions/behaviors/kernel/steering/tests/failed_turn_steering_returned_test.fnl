;; Regression for #662 (spec/tui-turns, `steeringReachesItsTurn`;
;; spec/core/tasks `absEndTurn`): steering accepted for a turn that ends by
;; :error or :cancelled comes back as one :steering-returned event and is never
;; injected after the next turn's prompt.

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local agent-mod (require :fen.core.agent))
(local steering (require :fen.extensions.steering.service))
(local tasks (require :fen.core.tasks))
(local turn-submit (require :fen.turn_submit))
(local events (require :fen.core.extensions.events))

(fn reset! []
  (test-api.reset!)
  (tasks.reset!)
  (let [p {}]
    (each [k v (pairs mock)] (tset p k v))
    (set p.name :mock)
    (register-registry.register :provider p :test)))

(fn make-agent [first-turn ctl]
  "Real agent wired to the real steering queue like interactive.fnl. The
   correction is typed (Enter while busy) at the first :llm-start; the first
   provider call returns FIRST-TURN, later ones answer normally."
  (var calls 0)
  (agent-mod.make-agent {:provider-name :mock
                         :model "mock"
                         :api-key :test
                         :get-steering (fn [] (steering.get-steering))
                         :get-follow-up (fn [] (steering.get-follow-up))
                         :on-event (fn [ev]
                                     (when (and (= ev.type :llm-start)
                                                (not ctl.typed?))
                                       (set ctl.typed? true)
                                       (assert.are.equal :queued
                                                         (. (steering.submit "also add tests"
                                                                             {:busy? true})
                                                            :action))
                                       (set ctl.cancel? true)))
                         :provider-options {:mock-script (fn [_req]
                                                           (set calls
                                                                (+ calls 1))
                                                           (if (= calls 1)
                                                               first-turn
                                                               "ok"))}}))

(fn run-turn [state line ?cancel-fn]
  "Start a main mailbox turn through turn_submit and resume it to completion,
   like the interactive tick."
  (turn-submit.start! state line
                      (fn [agent text cancelled?]
                        (agent-mod.step agent text (or ?cancel-fn cancelled?))))
  (var final nil)
  (while (not= (coroutine.status state.turn) :dead)
    (let [(ok? r) (coroutine.resume state.turn)]
      (assert.is_true ok? (tostring r))
      (set final r)))
  final)

(fn watch-returned []
  (let [seen []]
    (events.on :steering-returned #(table.insert seen $1) :returned-test)
    seen))

(fn check-returned-and-next-turn-clean [state returned]
  (assert.are.equal 1 (length returned))
  (assert.are.same ["also add tests"] (. returned 1 :texts))
  (assert.are.equal 0 (. (steering.queue-info) :steering-queued))
  (run-turn state "now write the docs")
  ;; user 1, failed assistant 2, user 3, assistant 4: no stale steering injected.
  (assert.are.equal 4 (length state.agent.messages))
  (assert.are.equal "now write the docs" (. state.agent.messages 3 :content)))

(describe "steering for a failed turn is handed back (#662)"
          (fn []
            (before_each reset!)
            (after_each reset!)
            (it "error path: the errored turn's steering is returned, not injected into the next turn"
                (fn []
                  (let [ctl {}
                        returned (watch-returned)
                        state {:agent (make-agent {:error "boom"} ctl)
                               :mailbox? true}
                        final1 (run-turn state "fix the parser")]
                    (assert.are.equal "[error] boom" final1)
                    (assert.are.equal :error
                                      (. state.agent.messages 2 :stop-reason))
                    (check-returned-and-next-turn-clean state returned))))
            (it "cancel path: the cancelled turn's steering is returned, not injected into the next turn"
                (fn []
                  (let [ctl {}
                        returned (watch-returned)
                        state {:agent (make-agent "never seen" ctl)
                               :mailbox? true}
                        final1 (run-turn state "fix the parser" #ctl.cancel?)]
                    (assert.are.equal "[cancelled]" final1)
                    (assert.are.equal :aborted
                                      (. state.agent.messages 2 :stop-reason))
                    (check-returned-and-next-turn-clean state returned))))
            (it "steering offered for a stale turn number is rejected"
                (fn []
                  (let [n (tasks.turn-start!)
                        stale (steering.queue! :steering "old" {:turn (- n 1)})
                        current (steering.queue! :steering "new" {:turn n})]
                    (assert.is_false stale.ok)
                    (assert.is_true current.ok)
                    (assert.are.same ["new"] (steering.get-steering)))))))
