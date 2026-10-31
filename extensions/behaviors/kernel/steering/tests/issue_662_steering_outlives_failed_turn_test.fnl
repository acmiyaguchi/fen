;; Known bug #662: steering queued during a turn that ends by :error or cancel stays queued, then is injected after the next turn's prompt.

(local {: known-bug} (require :fen.testing))
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

(fn stale-after-new-prompt? [agent]
  ;; 1 user prompt / 2 failed assistant / 3 user new prompt / 4 user stale steering / 5 assistant.
  (let [m agent.messages]
    (and (= (length m) 5) (= (. m 3 :role) :user)
         (= (. m 3 :content) "now write the docs") (= (. m 4 :role) :user)
         (= (. m 4 :content) "also add tests") (= (. m 5 :role) :assistant))))

(describe "#662 steering for a failed turn lands in the next turn"
          (fn []
            (before_each reset!)
            (after_each reset!)
            (it "error path: the queued correction is injected after the next prompt"
                (fn []
                  (known-bug 662
                             (fn []
                               (let [ctl {}
                                     agent (make-agent {:error "boom"} ctl)
                                     final1 (agent-mod.step agent
                                                            "fix the parser")]
                                 (assert.are.equal "[error] boom" final1)
                                 (assert.are.equal :error
                                                   (. agent.messages 2
                                                      :stop-reason))
                                 (let [queued (. (steering.queue-info)
                                                 :steering-queued)]
                                   (agent-mod.step agent "now write the docs")
                                   (and (= queued 1)
                                        (stale-after-new-prompt? agent))))))))
            (it "cancel path: the queued correction is injected after the next prompt"
                (fn []
                  (known-bug 662
                             (fn []
                               (let [ctl {}
                                     agent (make-agent "never seen" ctl)
                                     final1 (run-coop agent "fix the parser"
                                                      #ctl.cancel?)]
                                 (assert.are.equal "[cancelled]" final1)
                                 (assert.are.equal :aborted
                                                   (. agent.messages 2
                                                      :stop-reason))
                                 (let [queued (. (steering.queue-info)
                                                 :steering-queued)]
                                   (agent-mod.step agent "now write the docs")
                                   (and (= queued 1)
                                        (stale-after-new-prompt? agent))))))))))
