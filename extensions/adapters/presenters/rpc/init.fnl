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
(local turn-submit (require :fen.turn_submit))
(local clock (require :fen.util.clock))
(local text (require :fen.util.text))
(local turn-result (require :fen.util.turn_result))
(local wire (require :fen.util.wire))
(local wire-session (require :fen.util.wire_session))

(local M {})

(local OWNER :rpc-wire-events)
;; A busy tick resumes the turn once; idle waits only poll the control file.
(local BUSY-SLEEP-MS 10)
(local IDLE-SLEEP-MS 100)
(local DEFAULT-FINALIZE-NOTE
  "Stop working now. Without calling tools, give your final answer from what you have so far.")

(fn env [name]
  (text.blank->nil (os.getenv name)))

(fn steering []
  ;; Resolved at call time: the queue service is reloadable.
  (require :fen.extensions.steering.service))

(fn report! [msg]
  (io.stderr:write (.. "rpc presenter: " msg "\n")))

(fn send! [ch typ ?payload]
  "Stamp and append one wire event. Encoding failures go to stderr; the
   channel keeps running."
  (let [(line rej) (wire.next! ch.sender typ ?payload)]
    (if line
        (do (ch.out:write line "\n")
            (ch.out:flush))
        (report! (.. "cannot send " (tostring typ) ": "
                     (tostring (?. rej :reason)))))))

(fn M.forward! [ch ev]
  "Forward a bus event when it is a wire display event type."
  (let [typ (?. ev :type)]
    (when (and (not ch.exited?)
               (wire.event-type? typ)
               (not (wire-session.lifecycle-event? typ)))
      (send! ch typ (wire.normalize ev)))))

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
    (send! ch :exit {: status :error (when ?error (text.first-line (tostring ?error)))})
    (set ch.exited? true)
    (set ch.exit-status status)))

(fn finish! [ch]
  "Emit the run's one `result`, then `exit done`."
  (let [messages (run-messages ch)
        asst (turn-result.last-assistant messages)
        final-text (when asst (text.blank->nil (types.assistant-text asst)))]
    (send! ch :result {:final-text final-text
                       :stop-reason (tostring (or (?. asst :stop-reason) :none))
                       :usage (turn-result.sum-usage messages)
                       ;; A live child always answers from its whole conversation.
                       :context :complete})
    (exit! ch :done)))

(fn start-turn! [ch prompt ?final?]
  (let [state ch.state
        step-opts (when ?final? {:tool-choice :none})
        agent-step (fn [agent line cancel-fn]
                     (agent-mod.step agent line cancel-fn step-opts))]
    (set ch.turn (+ ch.turn 1))
    (set ch.active {:turn ch.turn
                    :final? ?final?
                    :start-index (+ (length (or state.agent.messages [])) 1)})
    (turn-submit.start! state prompt agent-step)
    (set ch.active.co state.turn)
    (send! ch :turn-started {:turn ch.turn})))

(fn interrupt-turn! [ch]
  ;; The step's cancel-fn fires at its next yield and pairs pending tool calls.
  (when ch.active
    (set ch.state.cancel-requested? true)))

(fn perform! [ch action ?msg]
  (if (= action :start-turn) (start-turn! ch ?msg.text)
      (= action :queue-steering) ((. (steering) :queue!) :steering ?msg.text)
      (= action :queue-follow-up) ((. (steering) :queue!) :follow-up ?msg.text)
      (= action :start-finalize-turn)
      (start-turn! ch (or (text.blank->nil ch.finalize-note) DEFAULT-FINALIZE-NOTE) true)
      (= action :interrupt-turn) (interrupt-turn! ch)
      (= action :abort) (if ch.active
                            (interrupt-turn! ch)
                            (exit! ch ch.status ch.error))
      (= action :exit) (exit! ch ch.status ch.error)
      (= action :finish) (finish! ch)
      nil))

(fn advance! [ch event]
  (let [entry (wire-session.advance ch.status event)]
    (when entry
      (set ch.status entry.next)
      (perform! ch entry.action nil))))

(fn fatal! [ch reason]
  (set ch.error reason)
  (advance! ch :fatal))

(fn apply-control! [ch msg]
  (let [entry (if (= msg.run ch.run)
                  (wire-session.decide ch.status msg.type)
                  {:status :rejected
                   :reason (.. "run " (tostring msg.run) " is not " ch.run)})]
    (send! ch :control-ack {:ref msg.seq :status entry.status
                            :reason entry.reason})
    (when (not= entry.status :rejected)
      (when (and (= msg.type :finalize) (= entry.status :accepted))
        (set ch.finalize-note msg.note))
      (set ch.status entry.next)
      (perform! ch entry.action msg))))

(fn handle-line! [ch line]
  (let [(msg rej) (wire.receive! ch.receiver line)]
    (if msg
        (apply-control! ch msg)
        (?. rej :fatal?)
        (fatal! ch rej.reason)
        (send! ch :control-ack (wire.rejection-ack rej)))))

(fn poll-controls! [ch]
  (let [(lines offset) (wire.read-lines ch.control-path ch.offset)]
    (set ch.offset offset)
    (each [_ line (ipairs lines)]
      (when (and (not ch.exited?) (not= line ""))
        (handle-line! ch line)))))

(fn turn-ended! [ch]
  (let [active ch.active
        state ch.state
        err state.turn-error
        messages (messages-from ch active.start-index)
        asst (turn-result.last-assistant messages)]
    (set ch.active nil)
    (send! ch :turn-complete {:turn active.turn
                              :stop-reason (if err "error"
                                               (tostring (or (?. asst :stop-reason) :none)))
                              :usage (turn-result.sum-usage messages)})
    (if err
        (fatal! ch (tostring err))
        (advance! ch (if active.final? :final-turn-done :turn-done)))))

(fn tick! [ch]
  (when ch.ctx.on-tick (ch.ctx.on-tick))
  (when (and ch.active (not= ch.state.turn ch.active.co))
    (turn-ended! ch)))

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
        (values nil "FEN_WIRE_CONTROL_PATH and FEN_WIRE_EVENT_PATH are required")
        (let [(out err) (io.open event-path :a)]
          (if (not out)
              (values nil (.. "cannot open " event-path ": " (tostring err)))
              {:ctx ctx
               :state ctx.state
               : control-path
               : out
               : run
               : deadline
               :now (or o.now os.time)
               :sleep (or o.sleep clock.sleep-ms)
               :sender (wire.sender :event run)
               :receiver (wire.receiver :control)
               :offset 0
               :status :starting
               :turn 0
               :run-start-index (+ (length (or (?. ctx :state :agent :messages) [])) 1)})))))

(fn M.init [ctx]
  "Open the channel before startup events so `agent-started` is forwarded."
  (let [(ch err) (open-channel ctx)]
    (if ch
        (do (set ctx.state.wire-channel ch)
            (events.unregister-by-owner OWNER)
            (events.on :* (fn [ev] (M.forward! ch ev)) OWNER))
        (error (.. "rpc presenter: " err)))))

(fn M.shutdown [ctx]
  (events.unregister-by-owner OWNER)
  (let [ch (?. ctx :state :wire-channel)]
    (when ch
      (pcall #(ch.out:close))
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
