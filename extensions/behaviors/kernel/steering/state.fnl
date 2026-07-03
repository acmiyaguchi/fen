;; Persistent steering/follow-up queue state. Not reloadable.
;;
;; Interactive-session-local: queues hold raw user lines awaiting injection
;; into the running turn (steering) or the next turn (follow-up). Cleared by
;; /new, /resume, /handoff, and /cancel-all; never persisted across runs.

;; @doc fen.extensions.steering.state.steering-queue
;; kind: data
;; signature: [string]
;; summary: Pending steering lines injected into the running turn at the next safe boundary.
;; tags: steering state queue

;; @doc fen.extensions.steering.state.follow-up-queue
;; kind: data
;; signature: [string]
;; summary: Pending follow-up lines submitted as fresh user turns after the current turn completes.
;; tags: steering state queue

;; @doc fen.extensions.steering.state.steering-mode
;; kind: data
;; signature: ":one-at-a-time"|":all"
;; summary: Drain mode for the steering queue - one line per boundary or the whole queue at once.
;; tags: steering state queue

;; @doc fen.extensions.steering.state.follow-up-mode
;; kind: data
;; signature: ":one-at-a-time"|":all"
;; summary: Drain mode for the follow-up queue - one line per turn end or the whole queue at once.
;; tags: steering state queue

{:steering-queue []
 :follow-up-queue []
 :steering-mode :one-at-a-time
 :follow-up-mode :one-at-a-time}
