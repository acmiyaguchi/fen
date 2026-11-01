;; Persistent session-holder, mailbox, and job-table state. Not reloadable
;; (listed in fen.core.extensions.loader.reloadable): /reload keeps the
;; holder, its registered coroutine, the turn number, every queued line, and
;; waiting exclusive jobs. Behavior lives in the reloadable `fen.core.tasks`.

;; @doc fen.core.tasks.state.machine
;; kind: data
;; signature: {:holder nil|{:kind :turn :n :hid :cancel?}|{:kind :exclusive :job :hid :cancel?} :n n :hid n :steer [{:seq :tag :text}] :follow-up [{:seq :tag :text}] :start? bool :first-up seq|nil :jobs [{:id :spec}] :next-job n :modes {:steering mode :follow-up mode} :next-seq n}
;; summary: The one session machine that fen.core.tasks.step advances: who holds the session, the current (or last) turn number and holder id, the running turn's steer lines, follow-ups, the start request and the line it starts, waiting exclusive jobs, and drain modes.
;; tags: tasks steering state

;; @doc fen.core.tasks.state.jobs
;; kind: data
;; signature: {hid {:co coroutine :hid hid :kind :turn|:exclusive :item item :n n :job job}}
;; summary: The job table: every holder id the machine issues has its coroutine registered here before anything else runs, until it is released or dropped.
;; tags: tasks state

;; @doc fen.core.tasks.state.attached?
;; kind: data
;; signature: boolean
;; summary: True while an interactive runtime drives the machine, so extension api.enqueue has a turn loop to deliver to.
;; tags: tasks steering state

{:machine {:holder nil
           :n 0
           :hid 0
           :steer []
           :follow-up []
           :start? false
           :first-up nil
           :jobs []
           :next-job 1
           :modes {:steering :one-at-a-time :follow-up :one-at-a-time}
           :next-seq 1}
 :jobs {}
 :attached? false}
