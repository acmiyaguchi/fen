;; Safe detached worktrees for read-only parallel subagent reviews.
;;
;; This is deliberately a small git wrapper, not a child runner.  Callers use
;; its returned cwd values with the ordinary subagent launch/registry path.

(local process (require :fen.util.process))
(local path (require :fen.util.path))
(local text (require :fen.util.text))

(local M {})
(local GIT-TIMEOUT 30)

(fn argv [& items]
  (let [out [:git]]
    (each [_ item (ipairs items)] (table.insert out item))
    out))

(fn git [cwd & items]
  (let [(ok? result) (pcall process.run-captured
                             {:argv (argv (table.unpack items))
                              :cwd cwd
                              :timeout-seconds GIT-TIMEOUT
                              :spill? true})]
    (if (not ok?)
        (values nil (tostring result))
        (not= result.exit-code 0)
        (values nil (text.trim (or result.output "git command failed")))
        (values (text.trim (or result.output "")) nil))))

(fn git-root [cwd]
  (git cwd "rev-parse" "--show-toplevel"))

(fn git-head [cwd]
  (git cwd "rev-parse" "HEAD"))

(fn clean? [cwd]
  (let [(status err) (git cwd "status" "--porcelain=v1" "--untracked-files=all")]
    (if err (values nil err) (values (= status "") nil))))

(fn sibling-path [root n]
  (.. (path.dirname root) "/" (path.basename root) "-review-"
      (tostring (os.time)) "-" (tostring n)))

;; @doc fen.extensions.subagent.worktrees.create
;; kind: function
;; signature: (create cwd ref count) -> [ReviewWorktree], string|nil
;; summary: Create detached sibling git worktrees for read-only review without changing the caller checkout.
;; tags: subagent git worktree review
(fn M.create [cwd ?ref ?count]
  (let [(root root-err) (git-root cwd)
        ref (or ?ref "HEAD")
        count (or ?count 1)]
    (if root-err
        (values nil (.. "cannot identify git worktree: " root-err))
        (or (not= (type count) :number) (< count 1) (> count 4))
        (values nil "worktree count must be between 1 and 4")
        (let [records []
              (ok? err) (pcall
                           (fn []
                             (for [n 1 count]
                               (let [target (sibling-path root n)
                                     (_added add-err) (git cwd "worktree" "add" "--detach" target ref)]
                                 (if add-err
                                     (error (.. "cannot create review worktree: " add-err))
                                     (let [(head head-err) (git-head target)
                                           (clean clean-err) (clean? target)]
                                       (if head-err
                                           (error (.. "cannot inspect review worktree: " head-err))
                                           clean-err
                                           (error (.. "cannot preflight review worktree: " clean-err))
                                           (not clean)
                                           (error "new review worktree is unexpectedly dirty")
                                           (table.insert records {:path target
                                                                  :owner-cwd cwd
                                                                  :source-root root
                                                                  :head head
                                                                  :ref ref
                                                                  :created? true}))))))))]
          (if ok?
              (values records nil)
              (do
                ;; A failed fan-out must not strand clean worktrees; cleanup
                ;; still applies its head/status ownership proof before removal.
                (each [_ record (ipairs records)] (M.cleanup record))
                (values nil (tostring err))))))))

;; @doc fen.extensions.subagent.worktrees.cleanup
;; kind: function
;; signature: (cleanup record) -> boolean, string|nil
;; summary: Remove one workflow-created detached review worktree only when its head and porcelain status are unchanged.
;; tags: subagent git worktree review cleanup
(fn M.cleanup [record]
  (if (not (and record record.created? record.path record.owner-cwd record.head))
      (values false "refusing to remove an untracked worktree")
      (let [(root root-err) (git-root record.path)
            (head head-err) (git-head record.path)
            (clean clean-err) (clean? record.path)]
        (if root-err
            (values false (.. "cannot verify review worktree: " root-err))
            (not= root record.path)
            (values false "refusing to remove a worktree whose root changed")
            head-err
            (values false (.. "cannot verify review worktree head: " head-err))
            (not= head record.head)
            (values false "refusing to remove a worktree whose HEAD changed")
            clean-err
            (values false (.. "cannot verify review worktree status: " clean-err))
            (not clean)
            (values false "refusing to remove a changed review worktree")
            (let [(_out err) (git record.owner-cwd "worktree" "remove" record.path)]
              (if err (values false (.. "cannot remove review worktree: " err))
                  (values true nil)))))))

M
