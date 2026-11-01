;; Persistent turn-mailbox state. Not reloadable (listed in
;; fen.core.extensions.loader.reloadable): /reload keeps the current turn and
;; every queued line. Behavior lives in the reloadable `fen.core.tasks`.

;; @doc fen.core.tasks.state.machine
;; kind: data
;; signature: {:turn n :running? bool :mailbox [{:id :turn :text}] :follow-ups [{:id :text}] :modes {:steering mode :follow-up mode} :next-id n :idle-start? bool}
;; summary: The one turn-mailbox machine state that fen.core.tasks.step advances: the main turn, turn-tagged steering lines, untagged follow-ups, and drain modes.
;; tags: tasks steering state

;; @doc fen.core.tasks.state.attached?
;; kind: data
;; signature: boolean
;; summary: True while an interactive runtime drives the machine, so extension api.enqueue has a turn loop to deliver to.
;; tags: tasks steering state

{:machine {:turn 0
           :running? false
           :mailbox []
           :follow-ups []
           :modes {:steering :one-at-a-time :follow-up :one-at-a-time}
           :next-id 1
           :idle-start? false}
 :attached? false}
