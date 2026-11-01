;; Small helper for submitting normal user turns from presenters/extensions.

(local coroutines (require :fen.util.coroutines))
(local tasks (require :fen.core.tasks))
(local M {})

(fn maybe-emit-user! [emit text opts]
  (when (and emit opts.emit-user?)
    (emit {:type :user :text text})))

(fn subagent-output-frame []
  "Pending background-subagent completions, framed as subagent output (#647).
   The subagent extension is optional and reloadable: resolved at call time."
  (let [(ok? runs) (pcall require :fen.extensions.subagent.runs)]
    (when ok?
      (let [(ok2? frame) (pcall runs.take-completion-frame!)]
        (when (and ok2? frame) frame)))))

(fn mailbox-turn [state body]
  "For the main run-state, open a turn-mailbox turn now and close it inside the
   coroutine, in the same resume that finishes the step, so no input can be
   accepted for a turn that already stopped draining (#662). Other agent
   states (side chat, headless session send) have no mailbox."
  (if state.mailbox?
      (let [n (tasks.turn-start!)]
        (fn []
          ;; xpcall keeps the crash site's traceback for the tick's error report.
          (let [result (table.pack (xpcall body debug.traceback))]
            (tasks.turn-end! n)
            (if (. result 1)
                (table.unpack result 2 result.n)
                (error (. result 2) 0)))))
      body))

(fn start-turn! [state text agent-step]
  (set state.turn-id (+ (or state.turn-id 0) 1))
  (set state.cancel-requested? false)
  (set state.turn-result nil)
  (set state.turn-error nil)
  (set state.turn
       (coroutines.create (mailbox-turn state
                                        (fn []
                                          (agent-step state.agent text
                                                      (fn []
                                                        state.cancel-requested?))))))
  (set state.busy? true)
  {:ok true :started true :turn-id state.turn-id})

(fn start! [state line agent-step]
  (let [frame (subagent-output-frame)
        text (if frame (.. frame "\n\n" line) line)]
    (start-turn! state text agent-step)))

(fn queue! [text queue]
  (tasks.queue! queue text))

(fn valid-when-busy? [v]
  (or (= v :reject) (= v :steering) (= v :follow-up)))

(fn M.submit! [state line ?opts agent-step emit]
  "Submit text as a normal user turn, or queue/reject while busy."
  (let [opts (or ?opts {})
        text (tostring (or line ""))
        when-busy (or opts.when-busy :reject)]
    (if (= text "")
        {:ok false :error "cannot submit an empty user turn"}
        (not (valid-when-busy? when-busy))
        {:ok false :error (.. "invalid when-busy mode: " (tostring when-busy))}
        (and state.busy? (not= when-busy :reject) (not state.mailbox?))
        ;; Only the main run-state owns the turn mailbox; queueing for a side
        ;; chat or headless state would steer the main turn instead.
        {:ok false :error "agent is busy and has no input queue"}
        state.busy?
        (if (= when-busy :steering)
            (do
              (maybe-emit-user! emit text opts)
              (tasks.steer-or-follow-up! text))
            (= when-busy :follow-up)
            (do
              (maybe-emit-user! emit text opts)
              (queue! text :follow-up))
            {:ok false :error "agent is busy"})
        (do
          (maybe-emit-user! emit text opts)
          (start! state text agent-step)))))

(tset M :start! start!)

M
