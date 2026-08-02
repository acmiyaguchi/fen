(local process (require :fen.util.process))

(fn fresh [git]
  (tset package.loaded :fen.util.process
        {:run-captured git})
  (tset package.loaded :fen.extensions.subagent.worktrees nil)
  (require :fen.extensions.subagent.worktrees))

(describe "subagent review worktrees"
  (fn []
    (var saved nil)
    (before_each
      (fn [] (set saved (. package.loaded :fen.util.process))))
    (after_each
      (fn []
        (tset package.loaded :fen.util.process saved)
        (tset package.loaded :fen.extensions.subagent.worktrees nil)))

    (it "creates detached sibling worktrees and records the clean preflight"
      (fn []
        (let [calls []
              worktrees (fresh
                          (fn [opts]
                            (table.insert calls opts)
                            (let [args (table.concat opts.argv " ")]
                              (if (string.find args "rev-parse --show-toplevel" 1 true)
                                  {:exit-code 0 :output (if (= opts.cwd "/repo") "/repo\n" opts.cwd)}
                                  (string.find args "rev-parse HEAD" 1 true)
                                  {:exit-code 0 :output "abc123\n"}
                                  (string.find args "status --porcelain=v1" 1 true)
                                  {:exit-code 0 :output ""}
                                  (string.find args "worktree add --detach" 1 true)
                                  {:exit-code 0 :output ""}
                                  {:exit-code 1 :output "unexpected git command"}))))
              (records err) (worktrees.create "/repo" "main" 2)]
          (assert.is_nil err)
          (assert.are.equal 2 (length records))
          (assert.are.equal "/repo" (. records 1 :source-root))
          (assert.are.equal "abc123" (. records 1 :head))
          (assert.is_true (. records 1 :created?))
          (assert.is_truthy (string.find (. records 1 :path) "/repo-review-" 1 true))
          (assert.are.equal 7 (length calls)))))

    (it "refuses cleanup when the workflow-created worktree changed"
      (fn []
        (var removed? false)
        (let [worktrees (fresh
                          (fn [opts]
                            (let [args (table.concat opts.argv " ")]
                              (if (string.find args "rev-parse --show-toplevel" 1 true)
                                  {:exit-code 0 :output "/repo-review\n"}
                                  (string.find args "rev-parse HEAD" 1 true)
                                  {:exit-code 0 :output "abc123\n"}
                                  (string.find args "status --porcelain=v1" 1 true)
                                  {:exit-code 0 :output " M changed.fnl\n"}
                                  (string.find args "worktree remove" 1 true)
                                  (do (set removed? true) {:exit-code 0 :output ""})
                                  {:exit-code 1 :output "unexpected git command"}))))
              (ok err) (worktrees.cleanup {:path "/repo-review" :owner-cwd "/repo"
                                            :head "abc123" :created? true})]
          (assert.is_false ok)
          (assert.are.equal "refusing to remove a changed review worktree" err)
          (assert.is_false removed?))))))
