;; Persistent subagent run data.
;;
;; Reload-excluded (see manifest.fnl) so /reload keeps active and recent run
;; records. It holds data only: every operation lives in the reloadable
;; fen.extensions.subagent.runs module, so a reload never leaves stale
;; functions pinned here and needs no migration.

{:data {:next-id 0
        :runs []
        ;; Once retention evicts a record, repeated-timeout counts are bounded
        ;; by the remaining history; remember that per task fingerprint.
        :runs-truncated? false
        :truncated-fingerprints {}
        :active {}
        ;; Detached review worktrees created by this workflow, data-only so
        ;; cleanup can prove ownership.
        :review-worktrees []
        ;; Detached (background) runs by id. Their records hold a live child
        ;; job, so public copies always pass through runs.copy-run.
        :jobs {}}}
