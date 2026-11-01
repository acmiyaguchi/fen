;; Wire-protocol child presenter for `--presenter rpc` (#516).
;;
;; A live child: it tails a private control JSONL file, drives one long-lived
;; conversation through the cooperative turn tick, and appends wire events to
;; an event JSONL file. `fen.util.wire` owns the message schema and
;; `fen.util.wire_session` owns the state table; this module only wires them
;; to the agent loop.

(local agent-mod (require :fen.core.agent))
(local events (require :fen.core.extensions.events))
(local types (require :fen.core.types))
(local usage-ledger (require :fen.core.extensions.usage_ledger))
(local turn-submit (require :fen.turn_submit))
(local clock (require :fen.util.clock))
(local text (require :fen.util.text))
(local turn-result (require :fen.util.turn_result))
(local wire (require :fen.util.wire))
(local wire-session (require :fen.util.wire_session))

(local M {})

(local OWNER :rpc-wire-events)
;; Same cadence as the TUI: a busy tick resumes the turn once, and an idle
;; tick only checks the control file's size.
(local BUSY-SLEEP-MS 30)
(local IDLE-SLEEP-MS 300)
;; Headroom for the result envelope and JSON escaping around final-text.
(local RESULT-OVERHEAD-BYTES 1024)
(local DEFAULT-FINALIZE-NOTE
       "Stop working now. Without calling tools, give your final answer from what you have so far.")

(fn env [name]
  (text.blank->nil (os.getenv name)))

(fn tasks []
  ;; Resolved at call time: the mailbox behavior is reloadable.
  (require :fen.core.tasks))

(fn report! [msg]
  (io.stderr:write (.. "rpc presenter: " msg "\n")))

(fn send! [ch typ ?payload]
  "Stamp and append one wire event. Encoding failures go to stderr; the
   channel keeps running."
  (let [(line rej) (wire.next! ch.sender typ ?payload)]
    (if line
        (do
          (ch.out:write line "\n")
          (ch.out:flush))
        (report! (.. "cannot send " (tostring typ) ": "
                     (tostring (?. rej :reason)))))))

;; Every queued line carries its control's wire seq as the mailbox tag, and
;; the mailbox hands the tag back on each injected, refused, released, and
;; cleared line: no ref bookkeeping lives here.
(local INJECTED {:steering-injected true :follow-up-injected true})

(fn refs-of [items]
  (let [refs (icollect [_ item (ipairs (or items []))]
               item.tag)]
    (when (> (length refs) 0) refs)))

(fn returned! [ch ev]
  "The turn mailbox handed back steering the turn ended without reading:
   name those controls in one `info`, so accepted controls are always
   accounted for."
  (let [texts (or ev.texts [])
        refs (icollect [_ tag (ipairs (or ev.tags []))]
               tag)]
    (when (> (length texts) 0)
      (send! ch :info
             {:summary (.. "returned " (length texts)
                           " unread steering line(s): the turn ended")
              :refs (when (> (length refs) 0) refs)}))))

(fn M.forward! [ch ev]
  "Forward a bus event when it is a wire display event type."
  (let [typ (?. ev :type)]
    (when (and (not ch.exited?) (= typ :steering-returned))
      (returned! ch ev))
    (when (and (not ch.exited?) (wire.event-type? typ)
               (not (wire-session.lifecycle-event? typ)))
      (let [out (wire.normalize ev)]
        (when (. INJECTED typ)
          (set out.ref (math.tointeger ev.tag)))
        (send! ch typ out)))))

(fn drop-queued! [ch]
  "Clear both input queues; name the dropped controls in one `info` event."
  (let [dropped ((. (tasks) :clear!))
        n (length dropped)]
    (when (> n 0)
      (send! ch :info {:summary (.. "dropped " n " queued input line(s)")
                       :refs (refs-of dropped)}))))

(fn run-messages [ch]
  (let [messages (or (?. ch.state :agent :messages) [])
        out []]
    (for [i ch.run-start-index (length messages)]
      (table.insert out (. messages i)))
    out))

(fn messages-from [ch start-index]
  (let [messages (or (?. ch.state :agent :messages) [])
        out []]
    (for [i start-index (length messages)]
      (table.insert out (. messages i)))
    out))

(fn exit! [ch status ?error]
  (when (not ch.exited?)
    (drop-queued! ch)
    (send! ch :exit
           {: status :error (when ?error (text.first-line (tostring ?error)))})
    (set ch.exited? true)
    (set ch.exit-status status)))

(fn spill-final-text [s ?path]
  "Write S to the parent-named file ?PATH (FEN_WIRE_RESULT_PATH, #667) or a new
   private temp file; return its path, or nil on failure."
  (let [(ok? path) (if ?path (values true ?path) (pcall os.tmpname))
        f (when ok? (io.open path :wb))]
    (if (and f (f:write s) (f:close))
        path
        (do
          (when f
            (pcall #(f:close)))
          (when ok? (os.remove path))
          nil))))

(fn result-line [ch payload]
  "Encode the result. A final-text too long for one line is spilled whole to
   :final-text-path and cut until the line fits, marked :truncated?; the last
   resort drops final-text and usage."
  (let [full payload.final-text
        encode #(wire.encode (wire.message :result ch.run (+ ch.sender.seq 1)
                                           payload)
                             :event)]
    (var line (encode))
    (when (and (not line) full)
      (set payload.final-text-path (spill-final-text full ch.result-path)))
    (var limit (- wire.MAX-LINE-BYTES RESULT-OVERHEAD-BYTES))
    (while (and (not line) full (> limit 0))
      (set payload.final-text (text.utf8-prefix full limit))
      (set payload.truncated? true)
      (set line (encode))
      (set limit (math.floor (/ limit 2))))
    (when (not line)
      (set payload.final-text nil)
      (set payload.usage nil)
      (set line (encode)))
    line))

(fn run-failed? [ch asst]
  "The run's last turn failed: the step's Outcome is not :ok, or the last
   assistant ended in error, tool use, or an abort (#632)."
  (let [outcome ch.last-outcome]
    (if (and (or outcome asst)
             (turn-result.failed? true (when asst [asst]) outcome))
        (values true (or (?. outcome :error)
                         (and asst
                              (.. "turn ended with stop-reason "
                                  (tostring asst.stop-reason)))
                         "turn failed"))
        false)))

(fn finish! [ch]
  "Emit the run's one `result`, then `exit done` (`exit failed` when the last
   turn failed)."
  ;; Any drop notice goes first so `result` stays right before `exit`.
  (drop-queued! ch)
  (let [messages (run-messages ch)
        asst (or (turn-result.last-assistant messages)
                 (turn-result.last-assistant (?. ch.state :agent :messages)))
        final-text (when asst (text.blank->nil (types.assistant-text asst)))
        line (result-line ch
                          {:final-text final-text
                           :stop-reason (tostring (or (?. asst :stop-reason)
                                                      :none))
                           :usage (or (usage-ledger.delta ch.run-marker)
                                      (turn-result.sum-usage messages))})]
    (if line
        (do
          (set ch.sender.seq (+ ch.sender.seq 1))
          (ch.out:write line "\n")
          (ch.out:flush))
        (report! "cannot encode result"))
    (let [(failed? reason) (run-failed? ch asst)]
      (if failed?
          (do
            (set ch.status :failed)
            (exit! ch :failed reason))
          (exit! ch :done)))))

;; fatal! is defined below start-turn!, which needs it when a start fails.
(local late {})

(fn start-turn! [ch prompt ?final?]
  (let [state ch.state
        step-opts (when ?final? {:tool-choice :none})
        agent-step (fn [agent line cancel-fn]
                     (let [(text outcome) (agent-mod.step agent line cancel-fn
                                                          step-opts)]
                       (set ch.last-outcome outcome)
                       (values text outcome)))]
    (set ch.turn (+ ch.turn 1))
    (set ch.active
         {:turn ch.turn
          :final? ?final?
          :marker (usage-ledger.mark!)
          :start-index (+ (length (or state.agent.messages [])) 1)})
    (let [started (turn-submit.start! state prompt agent-step)]
      (if started.ok
          (do
            (set ch.active.co state.turn)
            (set ch.active.n started.turn)
            (send! ch :turn-started {:turn ch.turn}))
          (do
            (set ch.active nil)
            (late.fatal! ch (.. "cannot start turn: " (tostring started.error))))))))

(fn interrupt-turn! [ch]
  ;; The step's cancel-fn fires at its next yield and pairs pending tool calls.
  (when ch.active
    (set ch.state.cancel-requested? true)))

(fn queue! [ch kind msg]
  ;; A steer names the active turn, so it can only reach that turn.
  (let [ref (math.tointeger msg.seq)
        result ((. (tasks) :offer!) msg.text
                                    (if (= kind :follow-up)
                                        {:tag ref :follow-up? true}
                                        {:tag ref :turn (?. ch.active :n)}))]
    (when (not result.ok)
      ;; Refused (no such turn running) or empty: account for the ref now.
      (send! ch :info {:summary (.. "dropped " (tostring kind) ": "
                                    (tostring result.error))
                       :refs [ref]}))))

(fn defer-exit! [ch f]
  "Run F now, or at the end of the current poll batch so every control line
   read in that batch is acknowledged before `result`/`exit` (#664)."
  (if ch.batch?
      (set ch.deferred f)
      (f)))

(fn perform! [ch action ?msg]
  (if (= action :finish) (defer-exit! ch #(finish! ch)) (= action :start-turn)
      (start-turn! ch ?msg.text) (= action :queue-steering)
      (queue! ch :steering ?msg) (= action :queue-follow-up)
      (queue! ch :follow-up ?msg) (= action :start-finalize-turn)
      (start-turn! ch (or (text.blank->nil ch.finalize-note)
                          DEFAULT-FINALIZE-NOTE) true)
      (= action :interrupt-turn) (interrupt-turn! ch) (= action :abort)
      (if ch.active
          (interrupt-turn! ch)
          (defer-exit! ch #(exit! ch ch.status ch.error)))
      (= action :exit) (defer-exit! ch #(exit! ch ch.status ch.error)) nil))

(fn advance! [ch event]
  (let [entry (wire-session.advance ch.status event)]
    (when entry
      (set ch.status entry.next)
      (perform! ch entry.action nil))))

(fn fatal! [ch reason]
  (set ch.error reason)
  (advance! ch :fatal))

(set late.fatal! fatal!)

(fn apply-control! [ch msg]
  (let [entry (if (= msg.run ch.run)
                  (wire-session.decide ch.status msg.type)
                  {:status :rejected
                   :reason (.. "run " (tostring msg.run) " is not " ch.run)})]
    (send! ch :control-ack {:ref msg.seq
                            :status entry.status
                            :reason entry.reason})
    (when (not= entry.status :rejected)
      (when (and (= msg.type :finalize) (= entry.status :accepted))
        ;; Finalizing is the parent ending the run: unapplied input is dropped.
        (drop-queued! ch)
        (set ch.finalize-note msg.note))
      (set ch.status entry.next)
      (perform! ch entry.action msg))))

(fn handle-line! [ch line]
  (let [(msg rej) (wire.receive! ch.receiver line)]
    (if msg (apply-control! ch msg)
        (?. rej :fatal?) (fatal! ch rej.reason)
        (send! ch :control-ack (wire.rejection-ack rej)))))

(fn poll-controls! [ch]
  (let [(lines status) (wire.read-lines! ch.reader)]
    (if (= status :truncated)
        (when (not (wire-session.terminal? ch.status))
          (fatal! ch (.. "control file truncated below offset "
                         ch.reader.offset)))
        (do
          (set ch.batch? true)
          (each [_ line (ipairs lines)]
            (when (and (not ch.exited?) (not= line ""))
              (handle-line! ch line)))
          (set ch.batch? false)
          (let [f ch.deferred]
            (set ch.deferred nil)
            (when (and f (not ch.exited?)) (f)))))))

(fn turn-ended! [ch]
  (let [active ch.active
        state ch.state
        err state.turn-error
        messages (messages-from ch active.start-index)
        asst (or (turn-result.last-assistant messages)
                 (turn-result.last-assistant (?. state :agent :messages)))]
    (set ch.active nil)
    (send! ch :turn-complete
           {:turn active.turn
            :stop-reason (if err "error"
                             (tostring (or (?. asst :stop-reason) :none)))
            :usage (or (usage-ledger.delta active.marker)
                       (turn-result.sum-usage messages))})
    (if err
        (fatal! ch (tostring err))
        (advance! ch (if active.final? :final-turn-done :turn-done)))
    ;; Never idle in a terminal state with nothing left to unwind.
    (when (and (not ch.exited?) (not ch.active)
               (wire-session.terminal? ch.status))
      (exit! ch ch.status ch.error))))

(fn adopt-turn! [ch]
  "A turn this presenter did not start (the runtime's idle follow-up tick)
   is tracked like a prompt in `ready`; anywhere else it is fatal."
  (if (= ch.status :ready)
      (do
        (set ch.status :running)
        (set ch.turn (+ ch.turn 1))
        (set ch.active {:turn ch.turn
                        :co ch.state.turn
                        :n (let [h ((. (tasks) :holder))]
                             (when (= h.kind :turn) h.n))
                        :marker (usage-ledger.mark!)
                        :start-index (+ (length (or ch.state.agent.messages []))
                                        1)})
        (send! ch :turn-started {:turn ch.turn}))
      (fatal! ch "untracked turn started")))

(fn tick! [ch]
  (when ch.ctx.on-tick (ch.ctx.on-tick))
  (when (and ch.active (not= ch.state.turn ch.active.co))
    (turn-ended! ch))
  (when (and ch.state.turn (not ch.active) (not ch.exited?))
    (adopt-turn! ch)))

(fn check-deadline! [ch]
  (when (and ch.deadline (>= (ch.now) ch.deadline)
             (not (wire-session.terminal? ch.status)))
    (set ch.error "run deadline exceeded")
    (advance! ch :deadline)))

(fn open-channel [ctx]
  "Build the channel from ctx.wire overrides (tests) or FEN_WIRE_* env."
  (let [o (or ctx.wire {})
        control-path (or o.control-path (env :FEN_WIRE_CONTROL_PATH))
        event-path (or o.event-path (env :FEN_WIRE_EVENT_PATH))
        run (or o.run (env :FEN_WIRE_RUN_ID) "run")
        deadline (or o.deadline (tonumber (env :FEN_WIRE_DEADLINE)))]
    (if (not (and control-path event-path))
        (values nil
                "FEN_WIRE_CONTROL_PATH and FEN_WIRE_EVENT_PATH are required")
        (let [(out err) (io.open event-path :a)]
          (if (not out)
              (values nil (.. "cannot open " event-path ": " (tostring err)))
              {:ctx ctx
               :state ctx.state
               :reader (wire.line-reader control-path)
               : out
               : run
               : deadline
               :result-path (or o.result-path (env :FEN_WIRE_RESULT_PATH))
               :now (or o.now os.time)
               :sleep (or o.sleep clock.sleep-ms)
               :sender (wire.sender :event run)
               :receiver (wire.receiver :control)
               :status :starting
               :turn 0
               :run-marker (usage-ledger.mark!)
               :run-start-index (+ (length (or (?. ctx :state :agent :messages)
                                               []))
                                   1)})))))

(fn M.init [ctx]
  "Open the channel before startup events so `agent-started` is forwarded."
  (let [(ch err) (open-channel ctx)]
    (if ch
        (do
          (set ctx.state.wire-channel ch)
          (events.unregister-by-owner OWNER)
          (events.on :* (fn [ev] (M.forward! ch ev)) OWNER))
        (error (.. "rpc presenter: " err)))))

(fn M.shutdown [ctx]
  (events.unregister-by-owner OWNER)
  (let [ch (?. ctx :state :wire-channel)]
    (when ch
      (pcall #(ch.out:close))
      (wire.close-reader! ch.reader)
      (set ctx.state.wire-channel nil))))

;; @doc fen.extensions.rpc.run
;; kind: function
;; signature: (run ctx) -> exit-code
;; summary: Serve one live wire-protocol run: emit `ready`, apply parent controls through the `fen.util.wire_session` table while stepping the agent cooperatively, and return 0 after `exit done` or 1 after any other exit status.
;; tags: rpc presenter wire subagent
(fn M.run [ctx]
  (when (not (?. ctx :state :wire-channel)) (M.init ctx))
  (let [ch ctx.state.wire-channel]
    ;; The run loop's context carries on-tick; init only saw the state.
    (set ch.ctx ctx)
    (send! ch :ready {})
    (advance! ch :started)
    (while (not ch.exited?)
      (poll-controls! ch)
      (when (not ch.exited?) (check-deadline! ch))
      (when (not ch.exited?) (tick! ch))
      (when (not ch.exited?)
        (ch.sleep (if ch.active BUSY-SLEEP-MS IDLE-SLEEP-MS))))
    (M.shutdown ctx)
    (if (= ch.exit-status :done) 0 1)))

(fn M.register [api]
  (api.on :error
          (fn [ev]
            (io.stderr:write (.. "error: " (tostring ev.error) "\n"))))
  (api.register :presenter
                {:name :rpc
                 :active? true
                 :init (fn [ctx] (M.init ctx))
                 :run (fn [ctx] (M.run ctx))
                 :shutdown (fn [ctx] (M.shutdown ctx))})
  true)

M
