(local state (require :fen.core.extensions.state))
(local test-api (require :fen.core.extensions.test_api))
(local recovery (require :fen.runtime_recovery))

(describe "fen.runtime_recovery"
  (fn []
    (before_each (fn [] (test-api.reset!)))
    (after_each (fn [] (test-api.reset!)))

    (it "resets only explicitly declared registry buckets"
      (fn []
        (let [ui state.ui
              logs [{:msg "keep"}]
              errors [{:error "keep"}]
              overlay {:worktree "/trusted"}
              runtime {:version "test"}
              info {:id :session}
              handle {:id :handle}]
          (table.insert state.tools-extra {:name :tool})
          (tset state.commands-extra :command {:name :command})
          (tset state.handlers :event [{:fn (fn [] nil)}])
          (tset state.extensions :example {:status :loaded})
          (tset state.reload-fingerprints :module "fingerprint")
          (set state.session.active-name :jsonl)
          (set state.session.backend {:name :old})
          (set state.session.info info)
          (set state.session.handle handle)
          (set state.ui.slot {:notify (fn [] nil)})
          (set state.logs logs)
          (set state.errors errors)
          (set state.dev-overlay overlay)
          (set state.runtime-info runtime)
          (let [(result err) (recovery.recover! :registries)]
            (assert.is_nil err)
            (assert.are.equal :registries result.scope)
            (assert.is_true (> (length result.buckets) 0))
            (assert.are.equal 0 (length state.tools-extra))
            (assert.is_nil (. state.commands-extra :command))
            (assert.is_nil (. state.handlers :event))
            (assert.is_nil (. state.extensions :example))
            (assert.is_nil (. state.reload-fingerprints :module))
            (assert.are.equal :jsonl state.session.active-name)
            (assert.is_nil state.session.backend)
            (assert.are.equal info state.session.info)
            (assert.are.equal handle state.session.handle)
            (assert.are.equal ui state.ui)
            (assert.is_nil state.ui.slot)
            (assert.are.equal logs state.logs)
            (assert.are.equal errors state.errors)
            (assert.are.equal overlay state.dev-overlay)
            (assert.are.equal runtime state.runtime-info)))))

    (it "rejects unsupported blanket recovery"
      (fn []
        (let [(result err) (recovery.recover! :everything)]
          (assert.is_nil result)
          (assert.are.equal "unsupported recovery scope" err))))))
