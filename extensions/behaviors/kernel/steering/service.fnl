;; Steering / follow-up input shell over the core turn mailbox.
;;
;; The queues, their turn tags, and the drain rules live in `fen.core.tasks`
;; (a pure Mealy step over non-reloadable `fen.core.tasks.state`). This module
;; keeps only the user-facing policy: `>`-prefixed lines are follow-ups, other
;; busy-time input steers the running turn, and the status/introspect views.
;;
;; Cross-extension consumers require this module, not the
;; `fen.extensions.steering` entry: the loader cache-busts entry modules on a
;; fresh load!, which would orphan earlier captures.

(local tasks (require :fen.core.tasks))

(local M {})

;; @doc fen.extensions.steering.service.queue-info
;; kind: function
;; signature: (queue-info) -> {:steering-queued n :follow-up-queued n :steering-mode mode :follow-up-mode mode}
;; summary: Current queue depths and drain modes, in the field names the status line consumes.
;; tags: steering queue status
(fn M.queue-info [] (tasks.info))

;; @doc fen.extensions.steering.service.queue-snapshot
;; kind: function
;; signature: (queue-snapshot) -> {:steering [line] :follow-up [line] :steering-mode mode :follow-up-mode mode}
;; summary: Copied queue contents plus modes for UI rendering such as the /queue panel.
;; tags: steering queue introspect
(fn M.queue-snapshot [] (tasks.snapshot))

(fn canonical-kind [kind]
  (if (= kind :follow-up) :follow-up
      (= kind :steering) :steering
      nil))

;; @doc fen.extensions.steering.service.queue!
;; kind: function
;; signature: (queue! kind text ?opts) -> {:ok true :queued true :queue kind}|{:ok false :error msg}
;; summary: Offer a line to the running turn's steering mailbox or the follow-up queue; steering is rejected when no turn runs or opts.turn is stale.
;; tags: steering queue
(fn M.queue! [kind text ?opts]
  (if (canonical-kind kind)
      (tasks.queue! kind text ?opts)
      {:ok false :error (.. "unknown queue: " (tostring kind))}))

;; @doc fen.extensions.steering.service.requeue!
;; kind: function
;; signature: (requeue! text from to) -> {:ok true :queued true :queue kind}|{:ok false :error msg}
;; summary: Move the most recent still-pending copy of a line from one queue to the end of the other; fails when no copy is pending or steering has no running turn.
;; tags: steering queue
(fn M.requeue! [text from to] (tasks.requeue! text from to))

;; @doc fen.extensions.steering.service.clear-queues!
;; kind: function
;; signature: (clear-queues! ?kind) -> nil
;; summary: Empty the named queue, or both when kind is nil or :all, and refresh status counts.
;; tags: steering queue
(fn M.clear-queues! [?kind] (tasks.clear! ?kind))

;; @doc fen.extensions.steering.service.set-queue-mode!
;; kind: function
;; signature: (set-queue-mode! kind mode) -> ok?
;; summary: Set a queue's drain mode to :one-at-a-time or :all, rejecting unknown kinds and modes.
;; tags: steering queue
(fn M.set-queue-mode! [kind mode]
  (if (canonical-kind kind) (tasks.set-mode! kind mode) false))

;; @doc fen.extensions.steering.service.get-steering
;; kind: function
;; signature: (get-steering) -> [line]
;; summary: Drain the running turn's steering lines by mode for injection at the agent's next safe boundary.
;; tags: steering queue agent
(fn M.get-steering [] (tasks.take! :steering))

;; @doc fen.extensions.steering.service.get-follow-up
;; kind: function
;; signature: (get-follow-up) -> [line]
;; summary: Drain the follow-up queue by its mode when the agent would otherwise stop.
;; tags: steering queue agent
(fn M.get-follow-up [] (tasks.take! :follow-up))

;; Deprecated shims for a session started before the turn mailbox existed:
;; its old `on-tick` and shutdown closures still call these after a /reload
;; into this code. Steering in such a session falls back to follow-ups until
;; fen restarts (the old run-state never opens mailbox turns).
(fn M.install-runtime! [runtime]
  (set M.legacy-runtime runtime)
  (tasks.attach! (not= runtime nil)))

(fn M.start-idle-follow-up! []
  (let [text (tasks.idle-tick!)]
    (if (and text M.legacy-runtime M.legacy-runtime.start-follow-up!)
        (do
          (M.legacy-runtime.start-follow-up! text)
          true)
        false)))

(fn follow-up-line? [line]
  (= (string.sub (or line "") 1 1) ">"))

(fn strip-follow-up-prefix [line]
  (let [s (string.sub (or line "") 2)]
    (or (string.match s "^%s*(.-)%s*$") "")))

(fn M.submit [line ctx]
  "Queueing decisions for non-slash input. The caller owns turn orchestration:
   it acts on :start; :queued has already been applied here."
  (if (not (?. ctx :busy?))
      {:action :start :text line}
      (let [result (if (follow-up-line? line)
                       (M.queue! :follow-up (strip-follow-up-prefix line))
                       ;; Busy without a mailbox turn (/reload, /handoff): the
                       ;; line becomes a follow-up rather than being rejected.
                       (tasks.steer-or-follow-up! line))
            text (if (follow-up-line? line) (strip-follow-up-prefix line) line)]
        (if result.ok
            {:action :queued :queue result.queue : text}
            {:action :error :error result.error}))))

(fn M.handle-input [input ctx]
  "Input-pipeline handler wrapping `submit`. `input` is
   {:kind :user-input :text string}; unknown kinds pass through unchanged so
   other handlers or the caller's default still apply."
  (let [input (or input {})]
    (if (not= (?. input :kind) :user-input)
        {:action :continue :input input}
        (M.submit (tostring (or input.text "")) (or ctx {})))))

M
