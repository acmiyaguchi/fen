;; Ref-accounting conformance: Quint traces of spec/wire/proofs/refs (`refs`,
;; from `initReady`, with --mbt action labels) are replayed through the real
;; rpc child (fen.extensions.rpc), the real mailbox (fen.core.tasks), and the
;; real turn submit path. Only the agent's turn body is scripted: it yields
;; until the replay tells it to drain a queue (emitting the injected events
;; the agent loop would) or to return. Exclusive jobs are real request-job!
;; holders, adopted (state.turn) or not. After every model step the wire's
;; terminal notices per control ref (turn-started.ref, *-injected.ref,
;; info.refs), each line control's ack status, and whether the child exited
;; must equal the model's `notes`, `acked`, and `exited`.
;; Run by spec/wire/proofs/refs/conform.sh, which generates the traces and
;; sets FEN_SPEC_ITF_INDEX; not part of `make test`.

(local json (require :fen.util.json))
(local wire (require :fen.util.wire))
(local agent-mod (require :fen.core.agent))
(local events (require :fen.core.extensions.events))
(local tasks (require :fen.core.tasks))
(local testing-tasks (require :fen.testing.tasks))
(local turn-submit (require :fen.turn_submit))
(local rpc (require :fen.extensions.rpc))

;; --negative: the scripted agent never drains its queues, so a harness that
;; cannot see a missing injected notice makes the check fail.
(local CORRUPT? (= (os.getenv :FEN_SPEC_CONFORM_CORRUPT) :1))
(local RUN "run-1")
(local MAX-TICKS 400)
(local MODE {:one :one-at-a-time :all :all})

(fn int [v]
  (if (= (type v) :table) (tonumber (. v "#bigint")) v))

(fn map-of [v]
  (let [out {}]
    (each [_ [k x] (ipairs (or (?. v "#map") []))]
      (tset out (int k) (if (= (type x) :table) (int x) x)))
    out))

(fn pick [st name]
  (let [p (?. st "mbt::nondetPicks" name)]
    (when (and p (= p.tag :Some)) p.value)))

(fn fake-step [ctl]
  "The agent's step, scripted: drain or return when the replay says so."
  (fn [_agent _line _cancel-fn _opts]
    (var done? false)
    (while (not done?)
      (coroutine.yield)
      (let [cmd ctl.cmd]
        (set ctl.cmd nil)
        (case cmd
          :exit (set done? true)
          :take-steer (let [(_ items) (tasks.take! :steering)]
                        (each [_ item (ipairs items)]
                          (events.emit {:type :steering-injected
                                        :text item.text
                                        :tag item.tag})))
          :take-follow-up (let [(_ items) (tasks.take! :follow-up)]
                            (each [_ item (ipairs items)]
                              (events.emit {:type :follow-up-injected
                                            :text item.text
                                            :tag item.tag}))))))
    nil))

(fn replay-trace [path]
  "Returns nil, or a mismatch description."
  (let [itf (with-open [f (assert (io.open path :r))]
              (json.decode (f:read :a)))
        states itf.states
        control-path (os.tmpname)
        event-path (os.tmpname)
        _ (do
            (os.remove event-path)
            (io.close (io.open control-path :w)))
        ctl {}
        state {:agent {:messages []} :opts {} :mailbox? true}
        reader (wire.line-reader event-path)
        receiver (wire.receiver :event)
        sender (wire.sender :control RUN)
        notes {}
        acks {}
        wire-seq {}
        jobs []
        ticks {:n 0}]
    (var err nil)
    (var step-i 1)

    (fn pump! []
      (let [(lines) (wire.read-lines! reader)]
        (each [_ line (ipairs lines)]
          (let [(msg) (wire.receive! receiver line)]
            (when msg
              (fn note! [ref]
                (when ref
                  (tset notes ref (+ 1 (or (. notes ref) 0)))))

              (case msg.type
                :control-ack (tset acks msg.ref msg.status)
                :turn-started (note! msg.ref)
                :steering-injected (note! msg.ref)
                :follow-up-injected (note! msg.ref)
                :info (each [_ r (ipairs (or msg.refs []))]
                        (note! r))
                :exit (set ctl.exited? true)))))))

    (fn compare! [i]
      (pump!)
      (let [st (. states i)
            m-notes (map-of st.notes)
            m-acked (map-of st.acked)]
        (for [r 0 (- (int st.nextRef) 1) &until err]
          (let [seq (. wire-seq r)
                got-n (or (. notes seq) 0)
                got-a (or (. acks seq) "")]
            (when (not= got-n (. m-notes r))
              (set err
                   (string.format "%s step %d (%s): ref %d notices model=%s code=%s"
                                  path i (tostring (. st "mbt::actionTaken")) r
                                  (tostring (. m-notes r)) got-n)))
            (when (and (not err) (not= got-a (. m-acked r)))
              (set err
                   (string.format "%s step %d: ref %d ack model=%s code=%s"
                                  path i r (. m-acked r) got-a)))))
        (when (and (not err) (not= (= true st.exited) (= true ctl.exited?)))
          (set err
               (string.format "%s step %d: exited model=%s code=%s" path i
                              (tostring st.exited) (tostring ctl.exited?))))))

    (fn send! [typ ?payload]
      ;; An empty steer fails the schema: write it raw (the child rejects it).
      (let [(line0 rej) (wire.next! sender typ ?payload)
            line (or line0
                     (do
                       (set sender.seq (+ sender.seq 1))
                       (json.encode (wire.message typ RUN sender.seq ?payload))))]
        (assert line (tostring (?. rej :reason)))
        (let [f (assert (io.open control-path :a))]
          (f:write line "\n")
          (f:close))
        sender.seq))

    (fn apply-step! [st]
      (case (. st "mbt::actionTaken")
        :parentLine (let [r (int (. states (- step-i 1) :nextRef))
                          kind (pick st :lk)
                          text (if (pick st :empty) "" (.. "line " r))]
                      (tset wire-seq r (send! kind {: text})))
        :parentCtl (send! (pick st :ok) {})
        :bodyExit (do
                    (set ctl.cmd :exit)
                    (set ctl.tick :resume))
        :takeSteerLines (when (not CORRUPT?)
                          (set ctl.cmd :take-steer)
                          (set ctl.tick :resume))
        :takeFollowUps (when (not CORRUPT?)
                         (set ctl.cmd :take-follow-up)
                         (set ctl.tick :resume))
        :tickStart (set ctl.tick :start)
        :exStart (let [job {}
                       co (testing-tasks.hold-exclusive! (fn []
                                                           (while (not job.done?)
                                                             (coroutine.yield))))]
                   (set job.co co)
                   (table.insert jobs job)
                   (when (pick st :adopt)
                     (set state.turn co)
                     (set state.busy? true)))
        :exEnd (set ctl.tick :ex-end)
        other (set err (.. path ": unmapped action " (tostring other)))))

    (fn on-tick []
      (let [what ctl.tick]
        (set ctl.tick nil)
        (case what
          ;; Resume until the body has read its command (a new body first
          ;; runs to its first yield).
          :resume
          (let [co state.turn]
            (var done? false)
            (var n 0)
            (while (and ctl.cmd (not done?) (< n 3))
              (set n (+ n 1))
              (let [(_ok? _value d?) (tasks.resume-current! co)]
                (set done? d?)))
            (when done? (turn-submit.drop! state)))
          :start
          (turn-submit.start-queued! state agent-mod.step)
          :ex-end
          (let [job (. jobs (length jobs))]
            (set job.done? true)
            (tasks.resume-current! job.co)
            (when (= state.turn job.co) (turn-submit.drop! state))))))

    (let [script (coroutine.create (fn []
                                     ;; The child has sent ready: start at the first step.
                                     (tasks.set-mode! :steering
                                                      (. MODE
                                                         (. states 1
                                                            :hSteerMode)))
                                     (tasks.set-mode! :follow-up
                                                      (. MODE
                                                         (. states 1
                                                            :hFollowMode)))
                                     (while (and (not err)
                                                 (<= (+ step-i 1)
                                                     (length states)))
                                       (set step-i (+ step-i 1))
                                       (apply-step! (. states step-i))
                                       (coroutine.yield)
                                       (when (not err) (compare! step-i)))))
          saved-step agent-mod.step
          ctx {: state
               :on-tick on-tick
               :wire {: control-path
                      : event-path
                      :run RUN
                      :now (fn [] 1000)
                      :sleep (fn [_ms]
                               (set ticks.n (+ ticks.n 1))
                               (when err (error err))
                               (if (and (= (coroutine.status script) :dead)
                                        (not (. states (length states) :exited)))
                                   ;; The trace ends with the run still live: stop here.
                                   (error :trace-end 0)
                                   (= (coroutine.status script) :dead)
                                   (when (and (not err) (> ticks.n MAX-TICKS))
                                     (set err (.. path ": child did not exit"))
                                     (error err))
                                   (let [(ok? e) (coroutine.resume script)]
                                     (when (not ok?) (set err (tostring e))))))}}]
      (set agent-mod.step (fake-step ctl))
      (let [(ok? e) (pcall rpc.run ctx)]
        (set agent-mod.step saved-step)
        (when (and (not ok?) (not err) (not= e :trace-end))
          (set err (.. path ": " (tostring e)))))
      ;; The child exited inside the step the script last applied.
      (when (and (not err) (= (coroutine.status script) :suspended))
        (compare! step-i)
        (when (and (not err) (< step-i (length states)))
          (set err (.. path ": child exited at step " step-i " of "
                       (length states))))))
    (turn-submit.drop! state)
    (wire.close-reader! reader)
    (os.remove control-path)
    (os.remove event-path)
    err))

(describe "rpc ref accounting conformance"
          (fn []
            (it "replays refs traces through the real rpc child"
                (fn []
                  (let [index (assert (os.getenv :FEN_SPEC_ITF_INDEX)
                                      "FEN_SPEC_ITF_INDEX is not set")
                        mismatches []]
                    (var n 0)
                    (each [path (io.lines index)]
                      (tasks.reset!)
                      (set n (+ n 1))
                      (let [e (replay-trace path)]
                        (when e (table.insert mismatches e))))
                    (tasks.reset!)
                    (print (string.format "refs conformance: %d traces, %d mismatches"
                                          n (length mismatches)))
                    (each [i e (ipairs mismatches)]
                      (when (<= i 5) (print e)))
                    (assert.are.equal 0 (length mismatches)))))))
