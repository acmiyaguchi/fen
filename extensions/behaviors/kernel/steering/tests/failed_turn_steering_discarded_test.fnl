;; Regression for #662 (spec/tui-turns, `steeringReachesItsTurn`):
;; steering queued during a turn that ends by :error or :cancelled is discarded/handed back,
;; and is never injected after the next turn's prompt.

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local agent-mod (require :fen.core.agent))
(local steering (require :fen.extensions.steering.service))
(local steering-state (require :fen.extensions.steering.state))

(fn reset! []
  (test-api.reset!)
  (steering.clear-queues!)
  (set steering-state.steering-mode :one-at-a-time)
  (set steering-state.follow-up-mode :one-at-a-time)
  (steering.install-runtime! nil)
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

(fn run-coop [agent line cancel-fn]
  (let [co (coroutine.create #(agent-mod.step agent line cancel-fn))]
    (var final nil)
    (while (not= (coroutine.status co) :dead)
      (let [(ok? r) (coroutine.resume co)]
        (assert.is_true ok? (tostring r))
        (set final r)))
    final))

(describe "steering for a failed turn is discarded (#662)"
          (fn []
            (before_each reset!)
            (after_each reset!)
            (it "error path: steering queued for errored turn is discarded and not injected into next turn"
                (fn []
                  (let [ctl {}
                        agent (make-agent {:error "boom"} ctl)
                        final1 (agent-mod.step agent "fix the parser")]
                    (assert.are.equal "[error] boom" final1)
                    (assert.are.equal :error (. agent.messages 2 :stop-reason))
                    (let [queued (. (steering.queue-info) :steering-queued)]
                      ;; Steering queue was cleared when the turn failed.
                      (assert.are.equal 0 queued)
                      (agent-mod.step agent "now write the docs")
                      ;; Messages has 4 items: user 1, assistant error 2, user 3, assistant 4 (no stale steering injected).
                      (assert.are.equal 4 (length agent.messages))
                      (assert.are.equal "now write the docs" (. agent.messages 3 :content))))))
            (it "cancel path: steering queued for cancelled turn is discarded and not injected into next turn"
                (fn []
                  (let [ctl {}
                        agent (make-agent "never seen" ctl)
                        final1 (run-coop agent "fix the parser" #ctl.cancel?)]
                    (assert.are.equal "[cancelled]" final1)
                    (assert.are.equal :aborted (. agent.messages 2 :stop-reason))
                    (let [queued (. (steering.queue-info) :steering-queued)]
                      ;; Steering queue was cleared when the turn failed.
                      (assert.are.equal 0 queued)
                      (agent-mod.step agent "now write the docs")
                      ;; Messages has 4 items: user 1, assistant aborted 2, user 3, assistant 4.
                      (assert.are.equal 4 (length agent.messages))
                      (assert.are.equal "now write the docs" (. agent.messages 3 :content))))))))
