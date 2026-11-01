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

(fn reset-turn-fields! [state]
  (set state.turn-id (+ (or state.turn-id 0) 1))
  (set state.cancel-requested? false)
  (set state.turn-result nil)
  (set state.turn-error nil))

(fn spawn-turn! [state text agent-step]
  "Create the turn coroutine for TEXT. The main run-state holds the session as
   a turn (`tasks.spawn-held`): acquired now, released when the body exits in
   any way, or by `drop!` if the coroutine is abandoned. Other agent states
   (side chat, headless session send) have no mailbox and no holder."
  (let [frame (subagent-output-frame)
        text (if frame (.. frame "\n\n" text) text)]
    (if state.mailbox?
        (do
          (var n nil)
          (let [body (fn []
                       (agent-step state.agent text
                                   (fn []
                                     (or state.cancel-requested?
                                         (tasks.cancel-requested? n)))))
                (co hid turn-or-why) (tasks.spawn-held :turn body)]
            (if co
                (do
                  (set n turn-or-why)
                  (reset-turn-fields! state)
                  (set state.turn co)
                  (set state.holder-id hid)
                  (set state.busy? true)
                  {:ok true :started true :turn-id state.turn-id :turn n})
                {:ok false :error turn-or-why})))
        (do
          (reset-turn-fields! state)
          (set state.turn
               (coroutines.create (fn []
                                    (agent-step state.agent text
                                                (fn []
                                                  state.cancel-requested?)))))
          (set state.busy? true)
          {:ok true :started true :turn-id state.turn-id}))))

(fn start-queued! [state agent-step]
  "The driver's idle tick: start the turn `tasks.next-start!` pops, if any."
  (let [item (tasks.next-start!)]
    (when item
      (spawn-turn! state item.text agent-step))))

(fn start! [state line agent-step]
  "Start LINE as a turn. For the main run-state every start goes through the
   mailbox: offer the line (idle: a follow-up plus a start request), then
   take the head follow-up with `next-start!` (FIFO: an older queued line runs
   first and this one follows at its natural stop)."
  (if (not state.mailbox?)
      (spawn-turn! state line agent-step)
      (not= :none (. (tasks.holder) :kind))
      {:ok false :error "agent is busy"}
      (let [offered (tasks.offer! line)]
        (if (not offered.ok)
            offered
            (or (start-queued! state agent-step)
                {:ok false :error "turn did not start"})))))

(fn drop! [state]
  "Forget the session's coroutine. Releases its holder (fenced, so a no-op
   when the body already released it): the path for every coroutine that is
   abandoned rather than resumed to completion."
  (when state.holder-id
    (tasks.release! state.holder-id)
    (set state.holder-id nil))
  (set state.turn nil)
  (set state.busy? false))

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
              (tasks.offer! text))
            (= when-busy :follow-up)
            (do
              (maybe-emit-user! emit text opts)
              (tasks.offer! text {:follow-up? true}))
            {:ok false :error "agent is busy"})
        (do
          (maybe-emit-user! emit text opts)
          (start! state text agent-step)))))

(tset M :start! start!)
(tset M :start-queued! start-queued!)
(tset M :drop! drop!)

M
