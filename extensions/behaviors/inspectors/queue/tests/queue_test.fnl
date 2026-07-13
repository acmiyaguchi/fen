;; Focused tests for the structured queue agent tool.

(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))
(local steering (require :fen.extensions.steering.service))
(local steering-state (require :fen.extensions.steering.state))

(fn reset-queues! []
  (steering.clear-queues!)
  (set steering-state.steering-mode :one-at-a-time)
  (set steering-state.follow-up-mode :one-at-a-time))

(fn fresh-tool []
  (test-api.reset!)
  (tset package.loaded :fen.extensions.queue nil)
  (tset package.loaded :fen.extensions.queue.commands.queue nil)
  (let [mod (require :fen.extensions.queue)
        api (test-api.make-runtime-api :queue)]
    (mod.register api)
    (let [registered (tool-registry.merged [])]
      (assert.are.equal 1 (length registered))
      (. registered 1))))

(fn execute [tool args]
  (. (tools.execute-call [tool] {:name :queue :arguments args} {}) :result))

(describe "fen.extensions.queue tool"
  (fn []
    (before_each reset-queues!)
    (after_each
      (fn []
        (reset-queues!)
        (test-api.reset!)))

    (it "is search-exposed and lists copied structured queue details"
      (fn []
        (steering.queue! :steering "adjust this")
        (steering.queue! :follow-up "then continue")
        (let [tool (fresh-tool)
              result (execute tool {:action "list"})]
          (assert.are.equal :search tool.exposure)
          (assert.is_false result.is-error?)
          (assert.are.equal :list result.details.action)
          (assert.are.same ["adjust this"] result.details.steering)
          (assert.are.same ["then continue"] result.details.follow-up)
          (assert.are.equal :one-at-a-time result.details.steering-mode)
          ;; Mutating returned details must not mutate service state.
          (table.insert result.details.steering "not queued")
          (assert.are.equal 1 (length (. (steering.queue-snapshot) :steering))))))

    (it "is read-only even when passed former mutation arguments"
      (fn []
        (steering.queue! :steering "user correction")
        (steering.queue! :follow-up "user follow-up")
        (let [tool (fresh-tool)]
          (each [_ args (ipairs [{:action "clear" :target "all"}
                                 {:action "set_mode" :queue "steering" :mode "all"}])]
            (let [result (execute tool args)
                  snapshot (steering.queue-snapshot)]
              (assert.is_false result.is-error?)
              (assert.are.equal :list result.details.action)
              (assert.are.same ["user correction"] snapshot.steering)
              (assert.are.same ["user follow-up"] snapshot.follow-up)
              (assert.are.equal :one-at-a-time snapshot.steering-mode)
              (assert.are.equal :one-at-a-time snapshot.follow-up-mode))))))))
