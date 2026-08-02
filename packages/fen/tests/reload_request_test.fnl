(local reload-request (require :fen.reload_request))

(describe "fen.reload_request"
  (fn []
    (it "defers an agent request made during an active turn until the idle boundary"
      (fn []
        (let [state {:busy? true :turn :active :reload-requests []}
              executed []
              (queued? request)
              (reload-request.enqueue!
                state {:scope "reload" :reason "load changed source"})]
          (assert.is_true queued?)
          (assert.are.equal :reload request.scope)
          (let [(ran? _request)
                (reload-request.drain!
                  state (fn [entry] (table.insert executed entry)))]
            (assert.is_false ran?))
          (assert.are.equal 1 (length state.reload-requests))
          (assert.are.equal 0 (length executed))
          (set state.busy? false)
          (set state.turn nil)
          (let [(ran? entry)
                (reload-request.drain!
                  state (fn [queued] (table.insert executed queued)))]
            (assert.is_true ran?)
            (assert.are.equal request entry)
            (assert.are.equal 1 (length executed))
            (assert.are.equal "load changed source" (. executed 1 :reason))
            (assert.are.equal 0 (length state.reload-requests))))))

    (it "rejects an unknown scope or a request without a reason"
      (fn []
        (let [(unknown? unknown-error)
              (reload-request.enqueue! {} {:scope "everything" :reason "bad"})
              (missing? missing-error)
              (reload-request.enqueue! {} {:scope "reload"})]
          (assert.is_false unknown?)
          (assert.are.equal "scope must be reload or registries" unknown-error)
          (assert.is_false missing?)
          (assert.are.equal "reason is required" missing-error))))))
