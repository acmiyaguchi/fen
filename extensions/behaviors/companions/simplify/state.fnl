;; Persistent simplify companion state. Not reloadable.

{:status :idle        ; :idle | :running
 :last-summary nil
 :last-error nil
 :last-base nil       ; ref/scope of the last run, nil for working-tree changes
 :run-state nil
 :active-turn-id nil
 :updated-at nil}
