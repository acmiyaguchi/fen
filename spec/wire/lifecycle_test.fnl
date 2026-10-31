;; Lifecycle conformance: Quint traces of spec/wire/model.qnt are replayed
;; through the real rpc child (fen.extensions.rpc, the real wire_session table,
;; the cooperative agent loop, the mock provider). A scripted parent writes
;; each model poll batch to the control file at the moment the model's child
;; polls, and steps the child's turn exactly as far as the model's next child
;; action; after every step the child's lifecycle events (ready, control-ack
;; ref/status, turn-started, turn-complete, the drop notice with its refs,
;; result, exit status) must equal the model's `c.out`, in order.
;; Run by spec/wire/conform.sh, which generates the traces and sets
;; FEN_SPEC_ITF_INDEX; not part of `make test`.

(local register-registry (require :fen.core.extensions.register))
(local events (require :fen.core.extensions.events))
(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local json (require :fen.util.json))
(local wire (require :fen.util.wire))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local steering (require :fen.extensions.steering.service))
(local rpc (require :fen.extensions.rpc))

(local MAIN (or (os.getenv :FEN_SPEC_ITF_MAIN) :current))
(local NS (.. MAIN "::wire::"))
(local RUN "run-1")
(local MAX-TICKS 5000)
(local STEP-TICKS 200)

;; Model actions the replay cannot reproduce deterministically in one
;; process: provider errors and throwing turns, process death (crash, kill,
;; death at the result line), and steering injection (the real agent drains
;; its queue at its own loop points, which the model abstracts to one
;; nondeterministic inject).
(local UNSUPPORTED {:childInject true
                    :childTurnError true
                    :childTurnThrow true
                    :childCrash true
                    :envCrashAtResult true
                    :parentKill true})

(fn int [v]
  (if (= (type v) :table) (tonumber (. v "#bigint")) v))

(fn set-items [v]
  (if (and (= (type v) :table) (. v "#set")) (. v "#set") v))

(fn sv [state name]
  (. state (.. NS name)))

;; ---- projections ----

(fn model-events [c]
  "The model's lifecycle events, in order, as comparable strings."
  (let [out []]
    (each [_ e (ipairs c.out)]
      (case e.kind
        :ready (table.insert out "ready")
        :ack (table.insert out (.. "ack " (int e.ref) " " e.status))
        :turnStarted (table.insert out "turn-started")
        :turnComplete (table.insert out "turn-complete")
        :dropped (table.insert out (.. "dropped ["
                                       (table.concat (icollect [_ r (ipairs e.refs)]
                                                       (tostring (int r)))
                                                     ",")
                                       "]"))
        :injected (table.insert out (.. "injected " (int e.ref)))
        :result (table.insert out "result")
        :exit (table.insert out (.. "exit " e.status))))
    out))

(fn n->s [x]
  (tostring (or (math.tointeger x) x)))

(fn real-events [seen]
  (let [out []]
    (each [_ ev (ipairs seen)]
      (case ev.type
        :ready (table.insert out "ready")
        :control-ack (table.insert out (.. "ack " (n->s ev.ref) " " ev.status))
        :turn-started (table.insert out "turn-started")
        :turn-complete (table.insert out "turn-complete")
        :info (when ev.refs
                (table.insert out (.. "dropped ["
                                      (table.concat (icollect [_ r (ipairs ev.refs)]
                                                      (n->s r))
                                                    ",")
                                      "]")))
        :steering-injected (table.insert out
                                         (.. "injected " (n->s (or ev.ref 0))))
        :result (table.insert out "result")
        :exit (table.insert out (.. "exit " ev.status))))
    out))

(fn same? [a b]
  (and (= (length a) (length b))
       (accumulate [ok true i x (ipairs a)]
         (and ok (= x (. b i))))))

;; ---- the real child ----

(fn register-mock! []
  (let [p {}]
    (each [k v (pairs mock)] (tset p k v))
    (set p.name :mock)
    (register-registry.register :provider p :test)))

(fn gate-tool [ctl]
  "A tool that runs until the controller releases it, yielding meanwhile."
  {:name :gate
   :label :gate
   :description :gate
   :parameters {:type :object :properties {}}
   :execute (fn [_args _ctx yield-fn]
              (set ctl.started (+ ctl.started 1))
              (let [mine ctl.started]
                (while (< ctl.released mine)
                  (when yield-fn (yield-fn))))
              {:content [(types.text-block "gate done")]})})

(fn long-text []
  (string.rep "x" (+ wire.MAX-LINE-BYTES 4096)))

(fn control-line [sender kind seq empty?]
  (let [payload (case kind
                  :prompt {:text (.. "task " seq)}
                  :steer {:text (if empty? "" (.. "steer " seq))}
                  _ nil)
        (line rej) (wire.next! sender kind payload)]
    (if line
        (do
          (assert (= sender.seq seq)
                  (.. "model seq " seq " but wire seq " sender.seq))
          line)
        (let [raw (wire.message kind RUN seq payload)]
          (set sender.seq seq)
          (json.encode raw)))))

(fn fatal-line []
  (let [msg (wire.message :close RUN 999 nil)]
    (set msg.v (+ wire.VERSION 1))
    (json.encode msg)))

(fn replay [states]
  "Replay one trace; returns nil on agreement, or a mismatch description."
  (let [control-path (os.tmpname)
        event-path (os.tmpname)
        _ (do
            (os.remove event-path)
            (io.close (io.open control-path :w)))
        ctl {:started 0
             :released 0
             :decision {:text "answer"}
             :allow false
             :tool-ids 0}
        script-fn (fn [_req]
                    ctl.decision)
        agent (agent-mod.make-agent {:provider-name :mock
                                     :model "mock"
                                     :api-key :test
                                     :tools [(gate-tool ctl)]
                                     :on-event (fn [ev] (events.emit ev))
                                     :get-steering (fn []
                                                     (steering.get-steering))
                                     :get-follow-up (fn []
                                                      (steering.get-follow-up))
                                     :provider-options {:mock-script script-fn}})
        state {: agent :opts {}}
        reader (wire.line-reader event-path)
        receiver (wire.receiver :event)
        sender (wire.sender :control RUN)
        seen []
        pump! (fn []
                (let [(lines) (wire.read-lines! reader)]
                  (each [_ line (ipairs lines)]
                    (let [(msg rej) (wire.receive! receiver line)]
                      (assert (= nil rej)
                              (.. "invalid wire event: " line " -> "
                                  (tostring (?. rej :reason))))
                      (table.insert seen msg)))))
        append! (fn [line]
                  (let [f (assert (io.open control-path :a))]
                    (f:write line "\n")
                    (f:close)))
        on-tick (fn []
                  (when (and ctl.allow state.turn)
                    (let [(ok? value) (coroutine.resume state.turn)]
                      (when (or (not ok?)
                                (= (coroutine.status state.turn) :dead))
                        (if ok? (set state.turn-result value)
                            (set state.turn-error value))
                        (set state.busy? false)
                        (set state.turn nil)
                        (set state.cancel-requested? false)
                        (turn-lifecycle.emit-complete! state ok? value)))))
        mismatch {:msg nil}
        ticks {:n 0}
        exited? (fn []
                  (pump!)
                  (accumulate [e false _ ev (ipairs seen)]
                    (or e (= ev.type :exit))))
        ;; Run child loop iterations (each one: poll, deadline, tick) until
        ;; DONE? holds, the child exits, or the step budget runs out.
        run-until (fn [done?]
                    (var n 0)
                    (while (and (not (done?)) (not (exited?)) (< n STEP-TICKS))
                      (set n (+ n 1))
                      (coroutine.yield))
                    (assert (or (done?) (exited?))
                            "replay: the child did not reach the model's step"))
        turn-ended? (fn [k]
                      (fn []
                        (pump!)
                        (>= (accumulate [m 0 _ ev (ipairs seen)]
                              (if (= ev.type :turn-complete) (+ m 1) m))
                            k)))
        script (fn []
                 (var prev nil)
                 (var started? false)
                 (each [i st (ipairs states) &until mismatch.msg]
                   (let [action (sv st :lastAction)
                         c (sv st :c)
                         p (sv st :p)]
                     (case action
                       :childStart (set started? true)
                       :childPoll (let [from (int (. (sv prev :c) :ctlRead))
                                        to (int c.ctlRead)]
                                    (for [j (+ from 1) to]
                                      (let [x (. p.ctlFile j)]
                                        (append! (control-line sender x.kind
                                                               (int x.seq)
                                                               x.empty))))
                                    (coroutine.yield))
                       :childToolCall (let [k (+ ctl.started 1)]
                                        (set ctl.tool-ids (+ ctl.tool-ids 1))
                                        (set ctl.decision
                                             {:tool-call {:id (.. "g"
                                                                  ctl.tool-ids)
                                                          :name :gate}})
                                        (set ctl.released ctl.started)
                                        (set ctl.allow true)
                                        (run-until #(>= ctl.started k))
                                        (set ctl.allow false))
                       (where (or :childAnswer :childUnwind)) (let [k (+ 1
                                                                         (accumulate [m 0 _ ev (ipairs seen)]
                                                                           (if (= ev.type
                                                                                  :turn-complete)
                                                                               (+ m
                                                                                  1)
                                                                               m)))]
                                                                (set ctl.decision
                                                                     {:text (if c.long
                                                                                (long-text)
                                                                                "answer")})
                                                                (set ctl.released
                                                                     ctl.started)
                                                                (set ctl.allow
                                                                     true)
                                                                (run-until (turn-ended? k))
                                                                (set ctl.allow
                                                                     false))
                       :childDeadline (do
                                        (set state.wire-channel.deadline 0)
                                        (coroutine.yield))
                       :childFatal (do
                                     (append! (fatal-line))
                                     (coroutine.yield))
                       _ nil)
                     (when started?
                       (pump!)
                       (let [want (model-events c)
                             got (real-events seen)]
                         (when (and (not (exited?)) (not (same? want got)))
                           (set mismatch.msg
                                (.. "after step " i " (" action
                                    ")\n    model: " (table.concat want " | ")
                                    "\n    code:  " (table.concat got " | "))))))
                     (set prev st))))
        co (coroutine.create script)
        ctx {: state
             : on-tick
             :wire {: control-path
                    : event-path
                    :run RUN
                    :deadline 1000000000
                    :now (fn [] 1000)
                    :sleep (fn [_ms]
                             (set ticks.n (+ ticks.n 1))
                             (assert (< ticks.n MAX-TICKS) "child did not exit")
                             (when (= (coroutine.status co) :suspended)
                               (let [(ok? err) (coroutine.resume co)]
                                 (assert ok? err)))
                             ;; trace over, child still running: stop it
                             (when (and (= (coroutine.status co) :dead)
                                        (not state.wire-channel.exited?))
                               (set state.wire-channel.exited? true)))}}]
    (steering.clear-queues!)
    (rpc.run ctx)
    (pump!)
    (wire.close-reader! reader)
    (os.remove control-path)
    (os.remove event-path)
    ;; A spilled final text: the full answer is in the named file. The parent
    ;; owns it, so the replay removes it, and the model must agree it spilled.
    (var spill-msg nil)
    (each [_ ev (ipairs seen)]
      (when (and (= ev.type :result) ev.final-text-path)
        (let [f (io.open ev.final-text-path :rb)
              body (when f (f:read :a))]
          (when f (f:close))
          (os.remove ev.final-text-path)
          (when (not= body (long-text))
            (set spill-msg "spill file does not hold the full answer"))
          (when (not (. (sv (. states (length states)) :c) :spilled))
            (set spill-msg "the code spilled but the model did not")))))
    (or mismatch.msg spill-msg
        ;; the run's whole event stream, once the child is done
        (let [last-c (sv (. states (length states)) :c)
              want (model-events last-c)
              got (real-events seen)]
          (when (and last-c.exited (not (same? want got)))
            (.. "at the end\n    model: " (table.concat want " | ")
                "\n    code:  " (table.concat got " | ")))))))

(fn supported? [states]
  (let [last-c (sv (. states (length states)) :c)]
    (and (accumulate [ok true _ st (ipairs states)]
           (and ok (not (. UNSUPPORTED (sv st :lastAction)))))
         ;; a steer queued mid-turn is injected at the agent's own loop
         ;; points; only traces whose steers start turns are replayed
         (= 0 (length (set-items last-c.accepted))))))

(fn read-index []
  (let [path (os.getenv :FEN_SPEC_ITF_INDEX)
        out []]
    (when path
      (each [line (io.lines path)]
        (when (not= line "") (table.insert out line))))
    out))

(describe (.. "wire lifecycle replay (" MAIN ")")
          (fn []
            (it "the real child emits the model's lifecycle events, step by step"
                (fn []
                  (register-mock!)
                  (let [files (read-index)
                        failures []]
                    (assert.is_true (> (length files) 0)
                                    "no traces (run spec/wire/conform.sh)")
                    (var replayed 0)
                    (var spilled 0)
                    (var scenarios {})
                    (each [_ file (ipairs files)]
                      (let [itf (with-open [f (assert (io.open file :r))]
                                  (json.decode (f:read :a)))
                            states itf.states]
                        (when (supported? states)
                          (set replayed (+ replayed 1))
                          (tset scenarios (sv (. states 1) :scenario) true)
                          (when (. (sv (. states (length states)) :c) :spilled)
                            (set spilled (+ spilled 1)))
                          (let [msg (replay states)]
                            (when msg
                              (table.insert failures (.. file ": " msg)))))))
                    (let [names (icollect [k _ (pairs scenarios)] k)]
                      (table.sort names)
                      (print (string.format "wire lifecycle: %d of %d traces replayed (%d spilled; scenarios %s), %d diverge"
                                            replayed (length files) spilled
                                            (table.concat names ",")
                                            (length failures))))
                    (assert.is_true (>= replayed 50)
                                    (.. "only " replayed " traces replayable"))
                    (assert.are.same [] [(. failures 1)]))))))
