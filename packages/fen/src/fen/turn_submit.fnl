;; Small helper for submitting normal user turns from presenters/extensions.

(local M {})

(fn maybe-emit-user! [emit text opts]
  (when (and emit opts.emit-user?)
    (emit {:type :user :text text})))

(fn start! [state text agent-step]
  (set state.cancel-requested? false)
  (set state.turn-result nil)
  (set state.turn-error nil)
  (set state.turn
       (coroutine.create
         (fn []
           (agent-step state.agent text (fn [] state.cancel-requested?)))))
  (set state.busy? true)
  {:ok true :started true})

(fn queue! [state text queue emit]
  (let [queue (if (= queue :follow-up) :follow-up :steering)]
    (if (= queue :follow-up)
        (table.insert state.follow-up-queue text)
        (table.insert state.steering-queue text))
    (when state.update-queue-status
      (state.update-queue-status))
    (emit {:type :queued :queue queue :text text})
    {:ok true :queued true :queue queue}))

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
        state.busy?
        (if (= when-busy :steering)
            (do
              (maybe-emit-user! emit text opts)
              (queue! state text :steering emit))
            (= when-busy :follow-up)
            (do
              (maybe-emit-user! emit text opts)
              (queue! state text :follow-up emit))
            {:ok false :error "agent is busy"})
        (do
          (maybe-emit-user! emit text opts)
          (start! state text agent-step)))))

(tset M :start! start!)
(tset M :queue! queue!)

M
