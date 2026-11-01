;; Persistent session-holder and mailbox state. Not reloadable (listed in
;; fen.core.extensions.loader.reloadable): /reload keeps the holder, the turn
;; number, and every queued line. Behavior lives in the reloadable
;; `fen.core.tasks`.

;; @doc fen.core.tasks.state.machine
;; kind: data
;; signature: {:kind :none|:turn|:exclusive :n n :hid n :steer [{:seq :tag :text}] :follow-up [{:seq :tag :text}] :start? bool :cancel? bool :modes {:steering mode :follow-up mode} :next-seq n}
;; summary: The one session machine that fen.core.tasks.step advances: who holds the session, the current (or last) turn number, the running turn's steer lines, follow-ups, the idle start request, the fenced cancel flag, and drain modes.
;; tags: tasks steering state

;; @doc fen.core.tasks.state.attached?
;; kind: data
;; signature: boolean
;; summary: True while an interactive runtime drives the machine, so extension api.enqueue has a turn loop to deliver to.
;; tags: tasks steering state

{:machine {:kind :none
           :n 0
           :hid 0
           :steer []
           :follow-up []
           :start? false
           :cancel? false
           :modes {:steering :one-at-a-time :follow-up :one-at-a-time}
           :next-seq 1}
 :attached? false}
