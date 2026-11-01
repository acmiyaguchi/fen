;; Agent reload requests are exclusive jobs of the one scheduler
;; (fen.core.tasks): they wait for running work and any pending turn start,
;; then dispatch their reload command inside the job.

(local reload-request (require :fen.core.reload_request))
(local tasks (require :fen.core.tasks))
(local hold (require :fen.testing.tasks))
(local command-registry (require :fen.core.extensions.register.command))

(fn with-dispatch [f]
  "Record command lines the jobs dispatch instead of running real commands."
  (let [orig command-registry.dispatch
        lines []]
    (set command-registry.dispatch (fn [line _state] (table.insert lines line)))
    (let [(ok? err) (pcall f lines)]
      (set command-registry.dispatch orig)
      (when (not ok?) (error err 0)))))

(fn drive! []
  "The idle tick: start the next job and run it to completion."
  (let [r (tasks.next-job! {:make-turn (fn [] (fn [] nil))})]
    (when r
      (while (not= :dead (coroutine.status r.co))
        (coroutine.resume r.co))
      r)))

(describe "fen.core.reload_request"
          (fn []
            (before_each (fn [] (tasks.reset!)))
            (after_each (fn [] (tasks.reset!)))
            (it "defers an agent request made during an active turn until the turn is done"
                (fn []
                  (with-dispatch (fn [lines]
                                   (let [state {}
                                         turn (hold.hold-turn! nil
                                                               (fn []
                                                                 (coroutine.yield)))
                                         (queued? request) (reload-request.enqueue! state
                                                                                    {:scope "reload"
                                                                                     :reason "load changed source"})]
                                     (assert.is_true queued?)
                                     (assert.are.equal :reload request.scope)
                                     (assert.are.equal :turn
                                                       (. (tasks.holder) :kind))
                                     (assert.are.equal 1
                                                       (. (tasks.snapshot)
                                                          :jobs))
                                     (assert.are.same [] lines)
                                     (coroutine.resume turn)
                                     (coroutine.resume turn)
                                     (assert.are.equal :exclusive
                                                       (. (drive!) :kind))
                                     (assert.are.same ["/reload"] lines)
                                     (assert.are.equal 0
                                                       (. (tasks.snapshot)
                                                          :jobs)))))))
            (it "waits for a pending turn start, then runs after that turn (no lost request)"
                (fn []
                  (with-dispatch (fn [lines]
                                   (let [state {}]
                                     (hold.hold-exclusive! (fn [] nil))
                                     (tasks.drop-current!)
                                     (tasks.offer! "queued prompt")
                                     (reload-request.enqueue! state
                                                              {:scope "reload"
                                                               :reason "r"})
                                     (assert.are.equal :turn (. (drive!) :kind)
                                                       "the turn goes first")
                                     (assert.are.same [] lines)
                                     (assert.are.equal :exclusive
                                                       (. (drive!) :kind))
                                     (assert.are.same ["/reload"] lines))))))
            (it "coalesces repeated same-scope requests with the latest reason winning"
                (fn []
                  (with-dispatch (fn [lines]
                                   (let [state {}]
                                     (hold.hold-turn!)
                                     (reload-request.enqueue! state
                                                              {:scope "reload"
                                                               :reason "first"})
                                     (reload-request.enqueue! state
                                                              {:scope "reload"
                                                               :reason "second"})
                                     (reload-request.enqueue! state
                                                              {:scope "registries"
                                                               :reason "recover"})
                                     (assert.are.equal 2
                                                       (. (tasks.snapshot)
                                                          :jobs))
                                     (tasks.drop-current!)
                                     (drive!)
                                     (drive!)
                                     (assert.are.same ["/reload"
                                                       "/reload --recover registries"]
                                                      lines))))))
            (it "a deferred dispatch that throws releases its job"
                (fn []
                  (let [orig command-registry.dispatch]
                    (set command-registry.dispatch
                         (fn [] (error "dispatch failed")))
                    (reload-request.enqueue! {}
                                             {:scope "reload" :reason "boom"})
                    ;; idle: the job started at once; the tick resumes it
                    (let [(ok? _ done?) (tasks.resume-current!)]
                      (assert.is_false ok?)
                      (assert.is_true done?))
                    (set command-registry.dispatch orig)
                    (assert.are.equal :none (. (tasks.holder) :kind))
                    (assert.is_nil (tasks.current-job)))))
            (it "rejects an unknown scope or a request without a reason"
                (fn []
                  (let [(unknown? unknown-error) (reload-request.enqueue! {}
                                                                          {:scope "everything"
                                                                           :reason "bad"})
                        (missing? missing-error) (reload-request.enqueue! {}
                                                                          {:scope "reload"})]
                    (assert.is_false unknown?)
                    (assert.are.equal "scope must be reload, registries, or extension"
                                      unknown-error)
                    (assert.is_false missing?)
                    (assert.are.equal "reason is required" missing-error))))))
