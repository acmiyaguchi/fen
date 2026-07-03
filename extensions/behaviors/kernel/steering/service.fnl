;; Steering / follow-up queue service.
;;
;; Owns the interactive input queues that used to live on main.fnl's run
;; state: steering lines injected into the running turn at safe boundaries,
;; and `>`-prefixed follow-up lines submitted as fresh turns after the
;; current turn completes. main.fnl wires the agent's get-steering /
;; get-follow-up callbacks through this module; /queue, /cancel-all,
;; /new, /resume, and /handoff mutate queues through the service API
;; instead of reaching into run state.
;;
;; Cross-extension consumers require this module, not the
;; `fen.extensions.steering` entry: the loader cache-busts entry modules on
;; a fresh load!, which would orphan earlier captures, while non-entry
;; modules keep one table identity that /reload mutates in place.
;;
;; Queue state lives in the non-reloadable sibling
;; `fen.extensions.steering.state`; this module is behavior only.

(local state (require :fen.extensions.steering.state))
(local events (require :fen.core.extensions.events))

(local M {})

(fn queue-of [kind]
  (if (or (= kind :follow-up) (= kind :followup))
      state.follow-up-queue
      (= kind :steering)
      state.steering-queue
      nil))

(fn canonical-kind [kind]
  (if (or (= kind :follow-up) (= kind :followup)) :follow-up
      (= kind :steering) :steering
      nil))

(fn drain! [q mode]
  (if (= mode :all)
      (let [out []]
        (while (> (length q) 0)
          (table.insert out (table.remove q 1)))
        out)
      (if (> (length q) 0)
          [(table.remove q 1)]
          [])))

(fn copy-list [xs]
  (let [out []]
    (each [_ v (ipairs (or xs []))]
      (table.insert out v))
    out))

;; @doc fen.extensions.steering.service.queue-info
;; kind: function
;; signature: (queue-info) -> {:steering-queued n :follow-up-queued n :steering-mode mode :follow-up-mode mode}
;; summary: Current queue depths and drain modes, in the field names the status line consumes.
;; tags: steering queue status
(fn M.queue-info []
  {:steering-queued (length state.steering-queue)
   :follow-up-queued (length state.follow-up-queue)
   :steering-mode state.steering-mode
   :follow-up-mode state.follow-up-mode})

(fn emit-counts! []
  ;; Presenters merge :set-status-info per-field, so emitting counts alone
  ;; leaves provider/model/approx-context untouched.
  (events.emit {:type :set-status-info :info (M.queue-info)}))

;; @doc fen.extensions.steering.service.queue-snapshot
;; kind: function
;; signature: (queue-snapshot) -> {:steering [line] :follow-up [line] :steering-mode mode :follow-up-mode mode}
;; summary: Copied queue contents plus modes for UI rendering such as the /queue panel.
;; tags: steering queue introspect
(fn M.queue-snapshot []
  {:steering (copy-list state.steering-queue)
   :follow-up (copy-list state.follow-up-queue)
   :steering-mode state.steering-mode
   :follow-up-mode state.follow-up-mode})

;; @doc fen.extensions.steering.service.queue!
;; kind: function
;; signature: (queue! kind text) -> {:ok true :queued true :queue kind}|{:ok false :error msg}
;; summary: Append a line to the steering or follow-up queue, emitting the :queued event and refreshed status counts.
;; tags: steering queue
(fn M.queue! [kind text]
  (let [kind (canonical-kind kind)
        q (queue-of kind)]
    (if (not q)
        {:ok false :error (.. "unknown queue: " (tostring kind))}
        (do
          (table.insert q text)
          (emit-counts!)
          (events.emit {:type :queued :queue kind :text text})
          {:ok true :queued true :queue kind}))))

;; @doc fen.extensions.steering.service.clear-queues!
;; kind: function
;; signature: (clear-queues! ?kind) -> nil
;; summary: Empty the named queue, or both when kind is nil or :all, and refresh status counts.
;; tags: steering queue
(fn M.clear-queues! [?kind]
  (when (or (= ?kind nil) (= ?kind :all) (= (canonical-kind ?kind) :steering))
    (while (> (length state.steering-queue) 0)
      (table.remove state.steering-queue)))
  (when (or (= ?kind nil) (= ?kind :all) (= (canonical-kind ?kind) :follow-up))
    (while (> (length state.follow-up-queue) 0)
      (table.remove state.follow-up-queue)))
  (emit-counts!))

;; @doc fen.extensions.steering.service.set-queue-mode!
;; kind: function
;; signature: (set-queue-mode! kind mode) -> ok?
;; summary: Set a queue's drain mode to :one-at-a-time or :all, rejecting unknown kinds and modes.
;; tags: steering queue
(fn M.set-queue-mode! [kind mode]
  (let [kind (canonical-kind kind)]
    (if (or (not kind) (not (or (= mode :one-at-a-time) (= mode :all))))
        false
        (do
          (if (= kind :steering)
              (set state.steering-mode mode)
              (set state.follow-up-mode mode))
          true))))

;; @doc fen.extensions.steering.service.get-steering
;; kind: function
;; signature: (get-steering) -> [line]
;; summary: Drain the steering queue by its mode for injection at the agent's next safe boundary.
;; tags: steering queue agent
(fn M.get-steering []
  (let [out (drain! state.steering-queue state.steering-mode)]
    (emit-counts!)
    out))

;; @doc fen.extensions.steering.service.get-follow-up
;; kind: function
;; signature: (get-follow-up) -> [line]
;; summary: Drain the follow-up queue by its mode when the agent finishes a turn.
;; tags: steering queue agent
(fn M.get-follow-up []
  (let [out (drain! state.follow-up-queue state.follow-up-mode)]
    (emit-counts!)
    out))

(fn follow-up-line? [line]
  (= (string.sub (or line "") 1 1) ">"))

(fn strip-follow-up-prefix [line]
  (let [s (string.sub (or line "") 2)]
    (or (string.match s "^%s*(.-)%s*$") "")))

;; @doc fen.extensions.steering.service.submit
;; kind: function
;; signature: (submit line ctx) -> {:action :start :text line}|{:action :queued :queue kind :text text}
;; summary: Decide what to do with non-slash user input - start a turn when idle, else queue as steering or stripped >-prefixed follow-up.
;; tags: steering queue input
(fn M.submit [line ctx]
  "Queueing decisions for non-slash input. The caller owns turn orchestration:
   it acts on :start; :queued has already been applied here."
  (if (not (?. ctx :busy?))
      {:action :start :text line}
      (if (follow-up-line? line)
          (let [text (strip-follow-up-prefix line)]
            (M.queue! :follow-up text)
            {:action :queued :queue :follow-up :text text})
          (do
            (M.queue! :steering line)
            {:action :queued :queue :steering :text line}))))

M
